import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:proxypin/native/ecapture.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/ecapture/binary.dart';
import 'package:proxypin/network/ecapture/event.dart';
import 'package:proxypin/network/ecapture/http_parser.dart';
import 'package:proxypin/network/ecapture/protobuf.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/cache.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/process_info.dart';
import 'package:proxypin/network/util/socket_address.dart';

/// 旁路接入 eCapture 明文：解析后直接写入 [ProxyServer.listeners]，不进 MITM。
/// eCapture `--ecaptureq` 作为 WebSocket 客户端连入，本服务在 28257 监听。
class ECaptureService {
  static const defaultWsUrl = 'ws://127.0.0.1:28257/';
  static const _wsPort = 28257;
  static const _maxPending = 256;
  static const _pendingTtl = Duration(seconds: 30);
  static const _updateDebounce = Duration(milliseconds: 200);

  static final ECaptureService instance = ECaptureService._();

  ECaptureService._();

  final ECaptureHttpParser _parser = ECaptureHttpParser();
  final Map<String, _PendingRequest> _pending = {};
  final ExpiringCache<int, ProcessInfo> _processCache =
      ExpiringCache<int, ProcessInfo>(const Duration(minutes: 5));
  final Map<int, Future<ProcessInfo>> _processInflight = {};

  ProxyServer? _server;
  io.HttpServer? _httpServer;
  io.WebSocket? _socket;
  StreamSubscription? _httpSub;
  Timer? _reconnect;
  Future<void> _eventChain = Future.value();
  final Map<String, Timer> _pendingUpdates = {};
  int _restartAttempt = 0;
  bool _enabled = false;
  bool _starting = false;
  String _status = 'stopped';

  bool get isRunning => _enabled && _httpServer != null;

  String get status => _status;

  void attach(ProxyServer server) {
    _server = server;
  }

  Future<void> setEnabled(bool enabled) async {
    if (!io.Platform.isAndroid) {
      _status = 'unsupported';
      return;
    }
    if (enabled) {
      _enabled = true;
      await start();
      return;
    }
    await stop();
  }

  Future<void> start() async {
    if (!io.Platform.isAndroid || !_enabled || _starting) return;
    _starting = true;
    _status = 'starting';
    try {
      await _listenWs();
      final binary = await ECaptureBinary.resolve();
      final native = await ECaptureNative.start(binaryPath: binary.path, wsUrl: defaultWsUrl);
      if (native['ok'] != true) {
        _status = (native['error'] as String?) ?? 'native start failed';
        logger.w('[eCapture] native start failed: $_status');
        _scheduleRestart();
        return;
      }
      if (_socket != null) {
        _status = 'running';
      }
    } catch (e, st) {
      _status = e.toString();
      logger.e('[eCapture] start failed', error: e, stackTrace: st);
      _scheduleRestart();
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    _enabled = false;
    _reconnect?.cancel();
    _reconnect = null;
    await _socket?.close();
    _socket = null;
    await _httpSub?.cancel();
    _httpSub = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
    try {
      await ECaptureNative.stop();
    } catch (e) {
      logger.d('[eCapture] native stop: $e');
    }
    _pending.clear();
    _processCache.clear();
    _processInflight.clear();
    for (final timer in _pendingUpdates.values) {
      timer.cancel();
    }
    _pendingUpdates.clear();
    _eventChain = Future.value();
    _restartAttempt = 0;
    _status = 'stopped';
  }

  Future<void> _listenWs() async {
    if (_httpServer != null) return;
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, _wsPort, shared: true);
    _httpServer = server;
    _httpSub = server.listen((request) {
      unawaited(_upgradeClient(request));
    }, onError: (e, st) {
      logger.w('[eCapture] ws server error $e');
      _scheduleRestart();
    });
    logger.i('[eCapture] websocket listening $defaultWsUrl');
  }

  Future<void> _upgradeClient(io.HttpRequest request) async {
    if (!io.WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    try {
      final socket = await io.WebSocketTransformer.upgrade(request);
      await _socket?.close();
      _socket = socket;
      _restartAttempt = 0;
      _status = 'running';
      logger.i('[eCapture] websocket client connected');
      socket.listen(
        _onFrame,
        onError: (e, st) {
          logger.w('[eCapture] websocket error $e');
          _onClientGone();
        },
        onDone: _onClientGone,
        cancelOnError: true,
      );
    } catch (e, st) {
      logger.w('[eCapture] websocket upgrade failed: $e', stackTrace: st);
    }
  }

  void _onClientGone() {
    _socket = null;
    if (!_enabled) return;
    logger.i('[eCapture] websocket client closed');
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (!_enabled) return;
    _status = 'reconnecting';
    _reconnect?.cancel();
    final shift = _restartAttempt > 4 ? 4 : _restartAttempt;
    _restartAttempt++;
    _reconnect = Timer(Duration(seconds: 2 << shift), () {
      if (_enabled) unawaited(_restartNative());
    });
  }

  Future<void> _restartNative() async {
    if (!_enabled || _starting) return;
    try {
      if (_socket != null && await ECaptureNative.isRunning()) {
        _status = 'running';
        return;
      }
      if (_socket == null) {
        await ECaptureNative.stop();
      }
      await start();
    } catch (e, st) {
      logger.w('[eCapture] native restart failed: $e', stackTrace: st);
      _scheduleRestart();
    }
  }

  void _onFrame(dynamic data) {
    try {
      final bytes = data is Uint8List
          ? data
          : data is List<int>
              ? Uint8List.fromList(data)
              : null;
      if (bytes == null) return;
      final entry = ECaptureProtobuf.decode(bytes);
      if (entry.logType == ECaptureLogEntry.logProcess && entry.runLog != null) {
        logger.d('[eCapture] ${entry.runLog}');
        return;
      }
      final event = entry.event;
      if (entry.logType != ECaptureLogEntry.logEvent || event == null) return;
      if (event.payload.isEmpty) return;
      _handleEvent(event);
    } catch (e, st) {
      logger.d('[eCapture] frame decode failed: $e', stackTrace: st);
    }
  }

  void _handleEvent(ECaptureEvent event) {
    _evictPending();
    _eventChain = _eventChain.then((_) async {
      if (event.isRequest) {
        await _handleRequest(event);
        return;
      }
      if (event.isResponse) {
        await _handleResponse(event);
        return;
      }
      if (_parser.parseRequest(event) != null) {
        await _handleRequest(event);
        return;
      }
      if (_parser.parseResponse(event) != null) {
        await _handleResponse(event);
        return;
      }
      _mergeUnknownBody(event);
    }).catchError((e, st) {
      logger.d('[eCapture] handle event failed: $e', stackTrace: st);
    });
  }

  Future<void> _handleRequest(ECaptureEvent event) async {
    final request = _parser.parseRequest(event);
    if (request == null) {
      final pending = _pending[event.pairKey];
      if (_mergePendingBody(event, requestSide: true) && pending != null) {
        _notifyUpdate(pending.request, event);
      }
      return;
    }
    _parser.attachMeta(request, event);
    request.hostAndPort ??= _parser.hostAndPort(event, request: request);
    request.packageSize = (request.packageSize ?? 0) + _payloadSize(event);
    final existing = _pending[event.pairKey];
    if (existing != null) {
      _mergeBody(existing.request, request.body);
      existing.request.packageSize = (existing.request.packageSize ?? 0) + _payloadSize(event);
      _notifyUpdate(existing.request, event);
      return;
    }
    _pending[event.pairKey] = _PendingRequest(request, DateTime.now());
    try {
      request.processInfo ??= await _processInfo(event);
    } catch (e, st) {
      logger.d('[eCapture] process lookup failed: $e', stackTrace: st);
      request.processInfo ??= _parser.processInfo(event);
    }
    _emitRequest(request, event);
  }

  Future<void> _handleResponse(ECaptureEvent event) async {
    final response = _parser.parseResponse(event);
    if (response == null) {
      final pending = _pending[event.pairKey];
      if (_mergePendingBody(event, requestSide: false) && pending?.response != null) {
        _notifyUpdate(pending!.response!, event);
      }
      return;
    }
    _parser.attachMeta(response, event);
    response.packageSize = (response.packageSize ?? 0) + _payloadSize(event);
    final pending = _pending[event.pairKey];
    if (pending == null) return;
    if (pending.response != null) {
      _mergeBody(pending.response!, response.body);
      pending.response!.packageSize = (pending.response!.packageSize ?? 0) + _payloadSize(event);
      _notifyUpdate(pending.response!, event);
      return;
    }
    pending.request.response = response;
    response.request = pending.request;
    response.requestId = pending.request.requestId;
    pending.response = response;
    _emitResponse(response, event);
  }

  Future<ProcessInfo> _processInfo(ECaptureEvent event) async {
    if (event.pid > 0) {
      final cached = _processCache.get(event.pid);
      if (cached != null) return cached;
      final inflight = _processInflight[event.pid];
      if (inflight != null) return inflight;
      final future = ECaptureNative.getProcessByPid(event.pid).then((info) {
        final resolved = info ?? _parser.processInfo(event);
        _processCache.set(event.pid, resolved);
        return resolved;
      }).whenComplete(() => _processInflight.remove(event.pid));
      _processInflight[event.pid] = future;
      return future;
    }
    return _parser.processInfo(event);
  }

  void _mergeUnknownBody(ECaptureEvent event) {
    final pending = _pending[event.pairKey];
    if (pending == null) return;
    if (pending.response != null) {
      if (_mergePendingBody(event, requestSide: false)) {
        _notifyUpdate(pending.response!, event);
      }
      return;
    }
    if (_mergePendingBody(event, requestSide: true)) {
      _notifyUpdate(pending.request, event);
    }
  }

  bool _mergePendingBody(ECaptureEvent event, {required bool requestSide}) {
    final pending = _pending[event.pairKey];
    if (pending == null) return false;
    final extra = _parser.extractBody(event);
    if (requestSide) {
      final merged = _mergeBody(pending.request, extra);
      pending.request.packageSize = (pending.request.packageSize ?? 0) + _payloadSize(event);
      return merged;
    }
    final response = pending.response;
    if (response == null) return false;
    final merged = _mergeBody(response, extra);
    response.packageSize = (response.packageSize ?? 0) + _payloadSize(event);
    return merged;
  }

  bool _mergeBody(HttpMessage target, List<int>? extra) {
    if (extra == null || extra.isEmpty) return false;
    final current = target.body;
    if (current == null || current.isEmpty) {
      target.body = extra;
      return true;
    }
    target.body = [...current, ...extra];
    return true;
  }

  int _payloadSize(ECaptureEvent event) => event.length > 0 ? event.length : event.payload.length;

  void _emitRequest(HttpRequest request, ECaptureEvent event) {
    final server = _server ?? ProxyServer.current;
    if (server == null) return;
    final channel = Channel.synthetic(_address(event));
    for (final listener in List<EventListener>.from(server.listeners)) {
      listener.onRequest(channel, request);
    }
  }

  void _emitResponse(HttpResponse response, ECaptureEvent event) {
    final server = _server ?? ProxyServer.current;
    if (server == null) return;
    final ctx = ChannelContext();
    ctx.currentRequest = response.request;
    ctx.host = response.request?.hostAndPort ?? _parser.hostAndPort(event);
    for (final listener in List<EventListener>.from(server.listeners)) {
      listener.onResponse(ctx, response);
    }
  }

  void _notifyUpdate(HttpMessage message, ECaptureEvent event) {
    final id = message.requestId;
    _pendingUpdates[id]?.cancel();
    _pendingUpdates[id] = Timer(_updateDebounce, () {
      _pendingUpdates.remove(id);
      final server = _server ?? ProxyServer.current;
      if (server == null) return;
      for (final listener in List<EventListener>.from(server.listeners)) {
        listener.onUpdate(message);
      }
    });
  }

  InetSocketAddress _address(ECaptureEvent event) {
    final ip = event.srcIp.isEmpty ? '127.0.0.1' : event.srcIp;
    io.InternetAddress address;
    try {
      address = io.InternetAddress(ip);
    } catch (_) {
      address = io.InternetAddress.loopbackIPv4;
    }
    return InetSocketAddress(address, event.srcPort);
  }

  void _evictPending() {
    final now = DateTime.now();
    _pending.removeWhere((_, value) => now.difference(value.at) > _pendingTtl);
    if (_pending.length <= _maxPending) return;
    final overflow = _pending.length - _maxPending;
    final keys = _pending.keys.take(overflow).toList();
    for (final key in keys) {
      _pending.remove(key);
    }
  }
}

class _PendingRequest {
  final HttpRequest request;
  final DateTime at;
  HttpResponse? response;

  _PendingRequest(this.request, this.at);
}
