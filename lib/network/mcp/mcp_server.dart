import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart' as http;
import 'package:proxypin/network/mcp/mcp_models.dart';
import 'package:proxypin/network/mcp/mcp_protocol.dart';
import 'package:proxypin/network/mcp/mcp_tools.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/random.dart';
import 'package:proxypin/utils/listenable_list.dart';

class McpSession {
  final String id;
  DateTime lastActive = DateTime.now();

  McpSession(this.id);

  void touch() {
    lastActive = DateTime.now();
  }
}

class McpSseClient {
  final String sessionId;
  final HttpRequest request;
  Timer? heartbeat;
  bool closed = false;
  int eventId = 0;

  McpSseClient({required this.sessionId, required this.request});

  HttpResponse get response => request.response;

  Future<void> writeRaw(String chunk) async {
    if (closed) {
      return;
    }
    try {
      response.write(chunk);
      await response.flush();
    } catch (_) {
      closed = true;
    }
  }

  Future<void> writeEvent(String event, Object data) async {
    eventId++;
    final payload = data is String ? data : jsonEncode(data);
    final buffer = StringBuffer()
      ..write('id: $eventId\n')
      ..write('event: $event\n');
    for (final line in payload.split('\n')) {
      buffer.write('data: $line\n');
    }
    buffer.write('\n');
    await writeRaw(buffer.toString());
  }

  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    heartbeat?.cancel();
    heartbeat = null;
    try {
      await response.close();
    } catch (_) {}
  }
}

class McpServerController {
  static McpServerController? _instance;

  final Configuration configuration;
  final ProxyServer Function() proxyServer;
  final ListenableList<http.HttpRequest> session;
  final McpAuditLog auditLog = McpAuditLog();

  HttpServer? _httpServer;
  McpJsonRpcHandler? _handler;
  final Map<String, McpSession> _sessions = {};
  final Map<String, McpSseClient> _sseClients = {};
  String? lastError;

  McpServerController._(this.configuration, this.proxyServer, this.session);

  static McpServerController instance({
    required Configuration configuration,
    required ProxyServer Function() proxyServer,
    required ListenableList<http.HttpRequest> session,
  }) {
    return _instance ??= McpServerController._(configuration, proxyServer, session);
  }

  static McpServerController? get current => _instance;

  bool get isRunning => _httpServer != null;
  int get sessionCount => {..._sessions.keys, ..._sseClients.keys}.length;
  int get port => configuration.mcpPort;

  String ensureToken() {
    if (configuration.mcpAuthToken.isEmpty) {
      configuration.mcpAuthToken = RandomUtil.randomString(24);
      configuration.flushConfig();
    }
    return configuration.mcpAuthToken;
  }

  String regenerateToken() {
    configuration.mcpAuthToken = RandomUtil.randomString(24);
    _sessions.clear();
    unawaited(closeSseClients());
    return configuration.mcpAuthToken;
  }

  Future<void> closeSseClients() async {
    final clients = _sseClients.values.toList();
    _sseClients.clear();
    for (final client in clients) {
      await client.close();
    }
  }

  Future<bool> start() async {
    if (isRunning) {
      return true;
    }
    lastError = null;
    ensureToken();
    try {
      final services = McpServices(
        session: session,
        proxyServer: proxyServer,
        bodyLimit: () => configuration.mcpBodyLimit,
        auditLog: auditLog,
      );
      _handler = McpJsonRpcHandler(services.buildRegistry());
      final server = await HttpServer.bind(InternetAddress.anyIPv4, configuration.mcpPort);
      server.idleTimeout = null;
      _httpServer = server;
      server.listen(_handleRequest, onError: (error, stack) {
        logger.e('MCP server listen error', error: error, stackTrace: stack);
      });
      logger.i('MCP listen on ${configuration.mcpPort}');
      return true;
    } catch (e, stack) {
      lastError = e.toString();
      _httpServer = null;
      logger.e('MCP bind failed', error: e, stackTrace: stack);
      return false;
    }
  }

  Future<void> stop() async {
    final clients = _sseClients.values.toList();
    _sseClients.clear();
    for (final client in clients) {
      await client.close();
    }
    _sessions.clear();
    final server = _httpServer;
    _httpServer = null;
    _handler = null;
    await server?.close(force: true);
  }

  Future<bool> restart() async {
    await stop();
    return start();
  }

  Future<bool> setEnabled(bool enabled) async {
    if (enabled) {
      return start();
    }
    await stop();
    return true;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      _cors(request.response);
      if (request.method == 'OPTIONS') {
        request.response.statusCode = 204;
        await request.response.close();
        return;
      }
      final ssePath = path == '/sse' || path == '/sse/';
      final messagePath = path == '/message' || path == '/messages';
      final mcpPath = path == '/mcp' || path == '/';
      if (!mcpPath && !ssePath && !messagePath) {
        await _write(request.response, 404, {'error': 'not found'});
        return;
      }
      if ((ssePath || messagePath) && !configuration.mcpSseEnabled) {
        await _write(request.response, 404, {'error': 'sse disabled'});
        return;
      }
      if (!_authorized(request)) {
        auditLog.add('auth', 'unauthorized ${request.method} ${request.uri}', ok: false);
        await _write(request.response, 401, {'error': 'unauthorized'});
        return;
      }

      if (request.method == 'DELETE') {
        final sessionId = request.headers.value('mcp-session-id') ?? request.uri.queryParameters['sessionId'];
        if (sessionId != null) {
          _sessions.remove(sessionId);
          final client = _sseClients.remove(sessionId);
          await client?.close();
        }
        request.response.statusCode = 204;
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && (mcpPath || ssePath)) {
        if (!configuration.mcpSseEnabled && mcpPath) {
          request.response.statusCode = 405;
          await request.response.close();
          return;
        }
        await _openSse(request, legacy: ssePath);
        return;
      }

      if (request.method != 'POST' || (!mcpPath && !messagePath)) {
        request.response.statusCode = 405;
        await request.response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final handler = _handler;
      if (handler == null) {
        await _write(request.response, 503, {'error': 'mcp not running'});
        return;
      }
      final result = await handler.handleRaw(body);
      final sessionId = _ensureSession(request);
      if (messagePath) {
        final sseClient = _sseClients[sessionId];
        if (result != null && sseClient != null && !sseClient.closed) {
          await sseClient.writeEvent('message', result);
        }
        request.response.statusCode = 202;
        await request.response.close();
        return;
      }
      if (result == null) {
        request.response.statusCode = 202;
        await request.response.close();
        return;
      }
      request.response.headers.set('mcp-session-id', sessionId);
      if (_wantsSseResponse(request) && configuration.mcpSseEnabled) {
        _prepareSseHeaders(request.response);
        request.response.statusCode = 200;
        request.response.write('event: message\ndata: ${jsonEncode(result)}\n\n');
        await request.response.flush();
        await request.response.close();
        return;
      }
      await _write(request.response, 200, result);
    } catch (e, stack) {
      logger.e('MCP request error', error: e, stackTrace: stack);
      try {
        await _write(request.response, 500, {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32603, 'message': e.toString()},
        });
      } catch (_) {}
    }
  }

  bool _authorized(HttpRequest request) {
    return mcpTokenMatches(
      configuration.mcpAuthToken,
      required: configuration.mcpAuthEnabled,
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
      queryToken: request.uri.queryParameters['token'],
    );
  }

  bool _wantsSseResponse(HttpRequest request) {
    final accept = (request.headers.value(HttpHeaders.acceptHeader) ?? '').toLowerCase();
    return accept.contains('text/event-stream') && !accept.contains('application/json');
  }

  void _prepareSseHeaders(HttpResponse response) {
    response.bufferOutput = false;
    response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-cache, no-transform');
    response.headers.set('Connection', 'keep-alive');
    response.headers.set('X-Accel-Buffering', 'no');
  }

  Future<void> _openSse(HttpRequest request, {required bool legacy}) async {
    final sessionId = _ensureSession(request);
    _prepareSseHeaders(request.response);
    request.response.statusCode = 200;
    request.response.headers.set('mcp-session-id', sessionId);

    final existing = _sseClients.remove(sessionId);
    await existing?.close();
    final client = McpSseClient(sessionId: sessionId, request: request);
    _sseClients[sessionId] = client;

    void cleanup() {
      if (_sseClients[sessionId] == client) {
        _sseClients.remove(sessionId);
      }
      client.heartbeat?.cancel();
      client.closed = true;
    }

    request.response.done.then((_) => cleanup()).catchError((_) => cleanup());

    if (legacy) {
      final host = request.headers.value(HttpHeaders.hostHeader) ?? '127.0.0.1:${configuration.mcpPort}';
      await client.writeRaw('event: endpoint\ndata: http://$host/message?sessionId=$sessionId\n\n');
    } else {
      await client.writeEvent('ping', {});
    }

    client.heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      client.writeRaw(': keepalive\n\n');
    });
  }

  String _ensureSession(HttpRequest request) {
    final existing = request.headers.value('mcp-session-id') ?? request.uri.queryParameters['sessionId'];
    if (existing != null && _sessions.containsKey(existing)) {
      _sessions[existing]!.touch();
      return existing;
    }
    final id = '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 32).toRadixString(36)}';
    _sessions[id] = McpSession(id);
    return id;
  }

  void _cors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type, Mcp-Session-Id, Last-Event-ID, Accept');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  }

  Future<void> _write(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
