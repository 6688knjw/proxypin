import 'dart:convert';

import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/mcp/mcp_models.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/utils/listenable_list.dart';

typedef McpToolHandler = Future<dynamic> Function(Map<String, dynamic> args);

class McpToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final McpToolHandler handler;

  McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'inputSchema': inputSchema,
    };
  }
}

class McpToolRegistry {
  final Map<String, McpToolDefinition> _tools = {};

  void register(McpToolDefinition tool) {
    _tools[tool.name] = tool;
  }

  List<Map<String, dynamic>> listTools() {
    return _tools.values.map((tool) => tool.toJson()).toList();
  }

  Future<dynamic> call(String name, Map<String, dynamic> args) {
    final tool = _tools[name];
    if (tool == null) {
      throw McpException.methodNotFound(name);
    }
    return tool.handler(args);
  }
}

class McpServices {
  final ListenableList<HttpRequest> session;
  final ProxyServer Function() proxyServer;
  final int Function() bodyLimit;
  final McpAuditLog auditLog;
  HistoryStorage? historyStorage;

  McpServices({
    required this.session,
    required this.proxyServer,
    required this.bodyLimit,
    required this.auditLog,
    this.historyStorage,
  });

  McpToolRegistry buildRegistry() {
    final registry = McpToolRegistry();
    registry.register(McpToolDefinition(
      name: 'list_traffic',
      description: 'List captured HTTP(S) traffic in the current session.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
          'method': {'type': 'string'},
          'host': {'type': 'string'},
          'status': {'type': 'integer'},
          'keyword': {'type': 'string'},
          'offset': {'type': 'integer'},
          'limit': {'type': 'integer'},
        },
      },
      handler: listTraffic,
    ));
    registry.register(McpToolDefinition(
      name: 'get_traffic',
      description: 'Get one captured request/response by requestId.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'requestId': {'type': 'string'},
        },
        'required': ['requestId'],
      },
      handler: getTraffic,
    ));
    registry.register(McpToolDefinition(
      name: 'list_history',
      description: 'List persisted HAR history records.',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: listHistory,
    ));
    registry.register(McpToolDefinition(
      name: 'get_history_traffic',
      description: 'Read traffic from a persisted history record.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'historyId': {'type': 'string'},
          'requestId': {'type': 'string'},
          'url': {'type': 'string'},
          'method': {'type': 'string'},
          'host': {'type': 'string'},
          'status': {'type': 'integer'},
          'keyword': {'type': 'string'},
          'offset': {'type': 'integer'},
          'limit': {'type': 'integer'},
        },
        'required': ['historyId'],
      },
      handler: getHistoryTraffic,
    ));
    registry.register(McpToolDefinition(
      name: 'send_request',
      description: 'Send an HTTP(S) request through the ProxyPin proxy.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'method': {'type': 'string'},
          'url': {'type': 'string'},
          'headers': {'type': 'object'},
          'body': {'type': 'string'},
        },
        'required': ['method', 'url'],
      },
      handler: sendRequest,
    ));
    registry.register(McpToolDefinition(
      name: 'replay_request',
      description: 'Replay a captured request, optionally overriding fields.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'requestId': {'type': 'string'},
          'method': {'type': 'string'},
          'url': {'type': 'string'},
          'headers': {'type': 'object'},
          'body': {'type': 'string'},
        },
        'required': ['requestId'],
      },
      handler: replayRequest,
    ));
    registry.register(McpToolDefinition(
      name: 'get_proxy_status',
      description: 'Get proxy running state, listen port and HTTPS capture flag.',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: getProxyStatus,
    ));
    registry.register(McpToolDefinition(
      name: 'list_rules',
      description: 'List script, rewrite, map and block rule summaries. Read-only.',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: listRules,
    ));
    return registry;
  }

  Future<Map<String, dynamic>> listTraffic(Map<String, dynamic> args) async {
    final filter = TrafficFilter.fromArgs(args);
    final matched = session.source.where(filter.matches).toList();
    final sliced = _page(matched, filter.offset, filter.limit);
    return {
      'total': matched.length,
      'offset': filter.offset,
      'items': sliced.map(trafficSummary).toList(),
    };
  }

  Future<Map<String, dynamic>> getTraffic(Map<String, dynamic> args) async {
    final requestId = args['requestId']?.toString();
    if (requestId == null || requestId.isEmpty) {
      throw McpException.invalidParams('requestId is required');
    }
    final request = _findInSession(requestId) ?? await _findInHistoryCache(requestId);
    if (request == null) {
      throw McpException.app('not_found', 'requestId not found');
    }
    return trafficDetail(request, bodyLimit());
  }

  Future<Map<String, dynamic>> listHistory(Map<String, dynamic> args) async {
    final storage = await _history();
    if (storage == null) {
      return {'items': []};
    }
    return {
      'items': storage.histories.asMap().entries.map((entry) {
        final item = entry.value;
        return {
          'historyId': '${entry.key}',
          'name': item.name,
          'requestLength': item.requestLength,
          'fileSize': item.fileSize,
          'createTime': item.createTime.toUtc().toIso8601String(),
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> getHistoryTraffic(Map<String, dynamic> args) async {
    final historyId = args['historyId']?.toString();
    if (historyId == null || historyId.isEmpty) {
      throw McpException.invalidParams('historyId is required');
    }
    final index = int.tryParse(historyId);
    final storage = await _history();
    if (storage == null || index == null || index < 0 || index >= storage.histories.length) {
      throw McpException.app('not_found', 'history record not found');
    }
    final item = storage.histories[index];
    final requests = await storage.getRequests(item);
    final filter = TrafficFilter.fromArgs(args);
    if (filter.requestId != null && filter.requestId!.isNotEmpty) {
      final request = requests.cast<HttpRequest?>().firstWhere(
            (element) => element?.requestId == filter.requestId,
            orElse: () => null,
          );
      if (request == null) {
        throw McpException.app('not_found', 'requestId not found');
      }
      return {
        'historyId': historyId,
        'total': 1,
        'items': [trafficDetail(request, bodyLimit())],
      };
    }
    final matched = requests.where(filter.matches).toList();
    final sliced = _page(matched, filter.offset, filter.limit);
    return {
      'historyId': historyId,
      'total': matched.length,
      'offset': filter.offset,
      'items': sliced.map((request) => trafficDetail(request, bodyLimit())).toList(),
    };
  }

  Future<Map<String, dynamic>> sendRequest(Map<String, dynamic> args) async {
    final methodName = args['method']?.toString();
    final url = args['url']?.toString();
    if (methodName == null || methodName.isEmpty || url == null || url.isEmpty) {
      throw McpException.invalidParams('method and url are required');
    }
    HttpMethod method;
    try {
      method = HttpMethod.valueOf(methodName);
    } catch (_) {
      throw McpException.invalidParams('invalid HTTP method');
    }
    if (Uri.tryParse(url) == null || !(url.startsWith('http://') || url.startsWith('https://'))) {
      throw McpException.app('invalid_url', 'invalid URL');
    }
    final request = HttpRequest(method, url);
    _applyHeaders(request, args['headers']);
    if (args['body'] != null) {
      request.body = utf8.encode(args['body'].toString());
    }
    final response = await _send(request);
    auditLog.add('send_request', '${method.name} $url -> ${response.status.code}');
    return trafficDetail(request..response = response, bodyLimit());
  }

  Future<Map<String, dynamic>> replayRequest(Map<String, dynamic> args) async {
    final requestId = args['requestId']?.toString();
    if (requestId == null || requestId.isEmpty) {
      throw McpException.invalidParams('requestId is required');
    }
    final original = _findInSession(requestId) ?? await _findInHistoryCache(requestId);
    if (original == null) {
      throw McpException.app('not_found', 'requestId not found');
    }
    final overrideUrl = args['url']?.toString();
    if (overrideUrl != null &&
        overrideUrl.isNotEmpty &&
        (Uri.tryParse(overrideUrl) == null ||
            !(overrideUrl.startsWith('http://') || overrideUrl.startsWith('https://')))) {
      throw McpException.app('invalid_url', 'invalid URL');
    }
    final request = original.copy(uri: overrideUrl);
    if (args['method'] != null) {
      try {
        request.method = HttpMethod.valueOf(args['method'].toString());
      } catch (_) {
        throw McpException.invalidParams('invalid HTTP method');
      }
    }
    if (args['headers'] is Map) {
      request.headers.clear();
      _applyHeaders(request, args['headers']);
    }
    if (args.containsKey('body')) {
      request.body = args['body'] == null ? null : utf8.encode(args['body'].toString());
    }
    final response = await _send(request);
    auditLog.add('replay_request', '${request.method.name} ${request.requestUrl} -> ${response.status.code}');
    return trafficDetail(request..response = response, bodyLimit());
  }

  Future<Map<String, dynamic>> getProxyStatus(Map<String, dynamic> args) async {
    final server = proxyServer();
    return {
      'running': server.isRunning,
      'port': server.port,
      'enableSsl': server.enableSsl,
    };
  }

  Future<Map<String, dynamic>> listRules(Map<String, dynamic> args) async {
    final items = <Map<String, dynamic>>[];
    try {
      final scripts = await ScriptManager.instance;
      for (final script in scripts.list) {
        items.add({
          'kind': 'script',
          'id': script.scriptPath,
          'name': script.name,
          'url': script.urls.join(','),
          'enabled': script.enabled,
        });
      }
    } catch (_) {}
    try {
      final rewrites = await RequestRewriteManager.instance;
      for (final rule in rewrites.rules) {
        items.add({
          'kind': 'rewrite',
          'name': rule.name,
          'url': rule.url,
          'enabled': rule.enabled,
        });
      }
    } catch (_) {}
    try {
      final maps = await RequestMapManager.instance;
      for (final rule in maps.rules) {
        items.add({
          'kind': 'map',
          'name': rule.name,
          'url': rule.url,
          'enabled': rule.enabled,
        });
      }
    } catch (_) {}
    try {
      final blocks = await RequestBlockManager.instance;
      for (final item in blocks.list) {
        items.add({
          'kind': 'block',
          'url': item.url,
          'enabled': item.enabled,
        });
      }
    } catch (_) {}
    return {'items': items};
  }

  Future<HttpResponse> _send(HttpRequest request) async {
    final server = proxyServer();
    if (!server.isRunning) {
      throw McpException.app('proxy_not_running', 'start the capture proxy first');
    }
    final proxyInfo = ProxyInfo.of('127.0.0.1', server.port);
    return HttpClients.proxyRequest(request, proxyInfo: proxyInfo, timeout: const Duration(seconds: 30));
  }

  HttpRequest? _findInSession(String requestId) {
    for (final request in session.source) {
      if (request.requestId == requestId) {
        return request;
      }
    }
    return null;
  }

  Future<HttpRequest?> _findInHistoryCache(String requestId) async {
    final storage = await _history();
    if (storage == null) {
      return null;
    }
    for (final item in storage.histories) {
      final cached = item.requests;
      if (cached == null) {
        continue;
      }
      for (final request in cached) {
        if (request.requestId == requestId) {
          return request;
        }
      }
    }
    return null;
  }

  Future<HistoryStorage?> _history() async {
    if (historyStorage != null) {
      return historyStorage;
    }
    try {
      historyStorage = await HistoryStorage.instance;
      return historyStorage;
    } catch (_) {
      return null;
    }
  }

  void _applyHeaders(HttpRequest request, dynamic headers) {
    if (headers is! Map) {
      return;
    }
    headers.forEach((key, value) {
      if (value == null) {
        return;
      }
      request.headers.set(key.toString(), value.toString());
    });
  }

  List<HttpRequest> _page(List<HttpRequest> source, int offset, int limit) {
    final start = offset < 0 ? 0 : offset;
    if (start >= source.length) {
      return const [];
    }
    final end = (start + (limit <= 0 ? 50 : limit)).clamp(0, source.length);
    return source.sublist(start, end);
  }
}
