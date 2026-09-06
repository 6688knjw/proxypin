import 'dart:convert';

import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_crypto_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/mcp/mcp_models.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/utils/curl.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/listenable_list.dart';
import 'package:proxypin/utils/python.dart';

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

  static const _filterProperties = {
    'url': {'type': 'string'},
    'method': {'type': 'string'},
    'host': {'type': 'string'},
    'status': {'type': 'integer'},
    'keyword': {'type': 'string'},
    'offset': {'type': 'integer'},
    'limit': {'type': 'integer'},
  };

  static const _requestIdSchema = {
    'type': 'object',
    'properties': {
      'requestId': {'type': 'string'},
    },
    'required': ['requestId'],
  };

  McpToolRegistry buildRegistry() {
    final registry = McpToolRegistry();
    void add(String name, String description, Map<String, dynamic> schema, McpToolHandler handler) {
      registry.register(McpToolDefinition(
        name: name,
        description: description,
        inputSchema: schema,
        handler: handler,
      ));
    }

    add('get_request_list', 'List captured HTTP(S) traffic summaries in the current session.', {
      'type': 'object',
      'properties': _filterProperties,
    }, getRequestList);
    add('get_request_detail', 'Get one captured request/response by requestId.', _requestIdSchema, getRequestDetail);
    add('get_request_body', 'Get request and/or response body by requestId.', {
      'type': 'object',
      'properties': {
        'requestId': {'type': 'string'},
        'which': {'type': 'string', 'description': 'request, response or both'},
      },
      'required': ['requestId'],
    }, getRequestBody);
    add('get_request_stats', 'Aggregate counts, methods, status codes and hosts for current session.', {
      'type': 'object',
      'properties': _filterProperties,
    }, getRequestStats);
    add('search_requests', 'Search captured traffic by keyword, URL, host, method or status.', {
      'type': 'object',
      'properties': _filterProperties,
    }, searchRequests);
    add('get_domain_summary', 'Group current session traffic by host.', {
      'type': 'object',
      'properties': _filterProperties,
    }, getDomainSummary);
    add('get_cookie_info', 'Parse Cookie and Set-Cookie headers for one request.', _requestIdSchema, getCookieInfo);
    add('compare_requests', 'Compare two captured requests.', {
      'type': 'object',
      'properties': {
        'requestId': {'type': 'string'},
        'otherRequestId': {'type': 'string'},
      },
      'required': ['requestId', 'otherRequestId'],
    }, compareRequests);
    add('analyze_encrypted_content', 'Detect encoding, JWT, Base64 and crypto-rule matches.', _requestIdSchema,
        analyzeEncryptedContent);
    add('replay_request', 'Replay a captured request, optionally overriding fields.', {
      'type': 'object',
      'properties': {
        'requestId': {'type': 'string'},
        'method': {'type': 'string'},
        'url': {'type': 'string'},
        'headers': {'type': 'object'},
        'body': {'type': 'string'},
      },
      'required': ['requestId'],
    }, replayRequest);
    add('generate_code', 'Generate curl, Python requests or fetch code for a captured request.', {
      'type': 'object',
      'properties': {
        'requestId': {'type': 'string'},
        'format': {'type': 'string', 'description': 'curl, python or fetch'},
      },
      'required': ['requestId'],
    }, generateCode);
    add('add_breakpoint', 'Add a URL breakpoint rule.', {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
        'name': {'type': 'string'},
        'method': {'type': 'string'},
        'interceptRequest': {'type': 'boolean'},
        'interceptResponse': {'type': 'boolean'},
        'enabled': {'type': 'boolean'},
      },
      'required': ['url'],
    }, addBreakpoint);
    add('remove_breakpoint', 'Remove a breakpoint by index, url or name.', {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer'},
        'url': {'type': 'string'},
        'name': {'type': 'string'},
      },
    }, removeBreakpoint);
    add('list_breakpoints', 'List breakpoint rules.', {'type': 'object', 'properties': {}}, listBreakpoints);
    add('get_pending_intercepts', 'List requests/responses paused at breakpoints.', {'type': 'object', 'properties': {}},
        getPendingIntercepts);
    add('release_intercept', 'Resume a paused breakpoint intercept.', {
      'type': 'object',
      'properties': {
        'requestId': {'type': 'string'},
        'phase': {'type': 'string', 'description': 'request or response'},
        'abort': {'type': 'boolean'},
        'method': {'type': 'string'},
        'url': {'type': 'string'},
        'headers': {'type': 'object'},
        'body': {'type': 'string'},
        'status': {'type': 'integer'},
      },
      'required': ['requestId'],
    }, releaseIntercept);
    add('list_rewrite_rules', 'List request rewrite rules.', {'type': 'object', 'properties': {}}, listRewriteRules);
    add('add_rewrite_rule', 'Add a request/response rewrite rule.', {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
        'name': {'type': 'string'},
        'type': {'type': 'string'},
        'enabled': {'type': 'boolean'},
        'method': {'type': 'string'},
        'redirectUrl': {'type': 'string'},
        'body': {'type': 'string'},
        'statusCode': {'type': 'integer'},
        'headers': {'type': 'object'},
      },
      'required': ['url', 'type'],
    }, addRewriteRule);
    add('remove_rewrite_rule', 'Remove a rewrite rule by index, url or name.', {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer'},
        'url': {'type': 'string'},
        'name': {'type': 'string'},
      },
    }, removeRewriteRule);
    add('list_scripts', 'List JavaScript intercept scripts.', {'type': 'object', 'properties': {}}, listScripts);
    add('get_script_content', 'Read script source by index or name.', {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer'},
        'name': {'type': 'string'},
      },
    }, getScriptContent);
    add('create_or_update_script', 'Create or update a JavaScript intercept script.', {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'url': {'type': 'string'},
        'script': {'type': 'string'},
        'enabled': {'type': 'boolean'},
      },
      'required': ['name', 'url', 'script'],
    }, createOrUpdateScript);
    add('find_sensitive_data', 'Find emails, phones, tokens and secrets in a request.', _requestIdSchema,
        findSensitiveData);
    add('analyze_auth', 'Analyze Authorization, Cookie and token fields.', _requestIdSchema, analyzeAuth);
    add('extract_api_endpoints', 'Extract unique API endpoints from current session.', {
      'type': 'object',
      'properties': _filterProperties,
    }, extractApiEndpoints);
    add('export_har', 'Export current session traffic as HAR JSON.', {
      'type': 'object',
      'properties': {
        ..._filterProperties,
        'requestIds': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'title': {'type': 'string'},
      },
    }, exportHar);
    add('import_har', 'Import HAR JSON into history storage.', {
      'type': 'object',
      'properties': {
        'har': {'type': 'string'},
        'name': {'type': 'string'},
      },
      'required': ['har'],
    }, importHar);

    add('list_traffic', 'Alias of get_request_list.', {'type': 'object', 'properties': _filterProperties}, listTraffic);
    add('get_traffic', 'Alias of get_request_detail.', _requestIdSchema, getTraffic);
    add('list_history', 'List persisted HAR history records.', {'type': 'object', 'properties': {}}, listHistory);
    add('get_history_traffic', 'Read traffic from a persisted history record.', {
      'type': 'object',
      'properties': {
        'historyId': {'type': 'string'},
        ..._filterProperties,
        'requestId': {'type': 'string'},
      },
      'required': ['historyId'],
    }, getHistoryTraffic);
    add('send_request', 'Send an HTTP(S) request through the ProxyPin proxy.', {
      'type': 'object',
      'properties': {
        'method': {'type': 'string'},
        'url': {'type': 'string'},
        'headers': {'type': 'object'},
        'body': {'type': 'string'},
      },
      'required': ['method', 'url'],
    }, sendRequest);
    add('get_proxy_status', 'Get proxy running state, listen port and HTTPS capture flag.',
        {'type': 'object', 'properties': {}}, getProxyStatus);
    add('list_rules', 'List script, rewrite, map and block rule summaries.', {'type': 'object', 'properties': {}},
        listRules);
    return registry;
  }

  Future<Map<String, dynamic>> getRequestList(Map<String, dynamic> args) => listTraffic(args);

  Future<Map<String, dynamic>> getRequestDetail(Map<String, dynamic> args) => getTraffic(args);

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
    final request = await _requireRequest(args);
    return trafficDetail(request, bodyLimit());
  }

  Future<Map<String, dynamic>> getRequestBody(Map<String, dynamic> args) async {
    final request = await _requireRequest(args);
    final which = (args['which']?.toString() ?? 'both').toLowerCase();
    final limit = bodyLimit();
    final result = <String, dynamic>{'requestId': request.requestId};
    if (which != 'response') {
      final payload = BodyPayload.fromBytes(request.body, limit);
      result['requestBody'] = payload.text;
      result['requestBodyTruncated'] = payload.truncated;
      result['requestBodyOriginalLength'] = payload.originalLength;
      if (payload.base64) {
        result['requestBodyEncoding'] = 'base64';
      }
    }
    if (which != 'request') {
      final payload = BodyPayload.fromBytes(request.response?.body, limit);
      result['responseBody'] = payload.text;
      result['responseBodyTruncated'] = payload.truncated;
      result['responseBodyOriginalLength'] = payload.originalLength;
      if (payload.base64) {
        result['responseBodyEncoding'] = 'base64';
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> getRequestStats(Map<String, dynamic> args) async {
    final matched = _filteredSession(args);
    final methods = <String, int>{};
    final statuses = <String, int>{};
    final hosts = <String, int>{};
    var withResponse = 0;
    var totalBytes = 0;
    for (final request in matched) {
      methods[request.method.name] = (methods[request.method.name] ?? 0) + 1;
      final host = request.requestUri?.host ?? request.hostAndPort?.host ?? '';
      if (host.isNotEmpty) {
        hosts[host] = (hosts[host] ?? 0) + 1;
      }
      final status = request.response?.status.code;
      if (status != null) {
        withResponse++;
        statuses['$status'] = (statuses['$status'] ?? 0) + 1;
      }
      totalBytes += (request.body?.length ?? 0) + (request.response?.body?.length ?? 0);
    }
    return {
      'total': matched.length,
      'withResponse': withResponse,
      'totalBytes': totalBytes,
      'methods': methods,
      'statuses': statuses,
      'hosts': hosts,
    };
  }

  Future<Map<String, dynamic>> searchRequests(Map<String, dynamic> args) => listTraffic(args);

  Future<Map<String, dynamic>> getDomainSummary(Map<String, dynamic> args) async {
    final matched = _filteredSession(args);
    final domains = <String, Map<String, dynamic>>{};
    for (final request in matched) {
      final host = request.requestUri?.host ?? request.hostAndPort?.host ?? '';
      if (host.isEmpty) {
        continue;
      }
      final item = domains.putIfAbsent(host, () {
        return {
          'host': host,
          'count': 0,
          'methods': <String, int>{},
          'statuses': <String, int>{},
        };
      });
      item['count'] = (item['count'] as int) + 1;
      final methods = item['methods'] as Map<String, int>;
      methods[request.method.name] = (methods[request.method.name] ?? 0) + 1;
      final status = request.response?.status.code;
      if (status != null) {
        final statuses = item['statuses'] as Map<String, int>;
        statuses['$status'] = (statuses['$status'] ?? 0) + 1;
      }
    }
    final items = domains.values.toList()
      ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    return {'total': items.length, 'items': items};
  }

  Future<Map<String, dynamic>> getCookieInfo(Map<String, dynamic> args) async {
    final request = await _requireRequest(args);
    return {
      'requestId': request.requestId,
      'requestCookies': _parseCookieHeader(request.headers.getList('Cookie') ?? request.cookies),
      'setCookies': _parseSetCookie(request.response?.headers.getList('Set-Cookie') ?? const []),
    };
  }

  Future<Map<String, dynamic>> compareRequests(Map<String, dynamic> args) async {
    final left = await _requireRequest(args);
    final otherId = args['otherRequestId']?.toString();
    if (otherId == null || otherId.isEmpty) {
      throw McpException.invalidParams('otherRequestId is required');
    }
    final right = _findInSession(otherId) ?? await _findInHistoryCache(otherId);
    if (right == null) {
      throw McpException.app('not_found', 'otherRequestId not found');
    }
    return {
      'left': trafficSummary(left),
      'right': trafficSummary(right),
      'diff': {
        'method': left.method.name != right.method.name,
        'url': left.requestUrl != right.requestUrl,
        'status': left.response?.status.code != right.response?.status.code,
        'requestHeaders': !_mapEquals(headerMap(left.headers), headerMap(right.headers)),
        'responseHeaders': !_mapEquals(
          left.response == null ? {} : headerMap(left.response!.headers),
          right.response == null ? {} : headerMap(right.response!.headers),
        ),
        'requestBody': left.bodyAsString != right.bodyAsString,
        'responseBody': (left.response?.bodyAsString ?? '') != (right.response?.bodyAsString ?? ''),
      },
    };
  }

  Future<Map<String, dynamic>> analyzeEncryptedContent(Map<String, dynamic> args) async {
    final request = await _requireRequest(args);
    CryptoRule? rule;
    try {
      rule = (await RequestCryptoManager.instance).getMatchingRule(request);
    } catch (_) {}
    final requestBody = request.bodyAsString;
    final responseBody = request.response?.bodyAsString ?? '';
    return {
      'requestId': request.requestId,
      'request': _encodingHints(requestBody, request.headers.contentType),
      'response': _encodingHints(responseBody, request.response?.headers.contentType ?? ''),
      'cryptoRule': rule == null
          ? null
          : {
              'name': rule.name,
              'urlPattern': rule.urlPattern,
              'field': rule.field,
            },
    };
  }

  Future<Map<String, dynamic>> generateCode(Map<String, dynamic> args) async {
    final request = await _requireRequest(args);
    final format = (args['format']?.toString() ?? 'curl').toLowerCase();
    late final String code;
    switch (format) {
      case 'python':
      case 'python_requests':
        code = copyAsPythonRequests(request);
        break;
      case 'fetch':
      case 'javascript':
      case 'js':
        code = copyAsFetch(request);
        break;
      case 'curl':
        code = curlRequest(request);
        break;
      default:
        throw McpException.invalidParams('format must be curl, python or fetch');
    }
    return {'requestId': request.requestId, 'format': format, 'code': code};
  }

  Future<Map<String, dynamic>> addBreakpoint(Map<String, dynamic> args) async {
    final url = args['url']?.toString();
    if (url == null || url.isEmpty) {
      throw McpException.invalidParams('url is required');
    }
    final manager = await RequestBreakpointManager.instance;
    final rule = RequestBreakpointRule(
      enabled: args['enabled'] is bool ? args['enabled'] as bool : true,
      name: args['name']?.toString(),
      url: url,
      interceptRequest: args['interceptRequest'] is bool ? args['interceptRequest'] as bool : true,
      interceptResponse: args['interceptResponse'] is bool ? args['interceptResponse'] as bool : true,
      method: _optionalMethod(args['method']),
    );
    manager.add(rule);
    auditLog.add('add_breakpoint', url);
    return {'ok': true, 'index': manager.list.length - 1, 'rule': rule.toJson()};
  }

  Future<Map<String, dynamic>> removeBreakpoint(Map<String, dynamic> args) async {
    final manager = await RequestBreakpointManager.instance;
    final index = _findIndex(manager.list.length, args, (i) {
      final rule = manager.list[i];
      return _matchNameOrUrl(args, name: rule.name, url: rule.url);
    });
    if (index == null) {
      throw McpException.app('not_found', 'breakpoint not found');
    }
    final removed = manager.list[index];
    manager.remove(removed);
    auditLog.add('remove_breakpoint', removed.url);
    return {'ok': true, 'removed': removed.toJson()};
  }

  Future<Map<String, dynamic>> listBreakpoints(Map<String, dynamic> args) async {
    final manager = await RequestBreakpointManager.instance;
    return {
      'enabled': manager.enabled,
      'items': [
        for (var i = 0; i < manager.list.length; i++) {'index': i, ...manager.list[i].toJson()},
      ],
    };
  }

  Future<Map<String, dynamic>> getPendingIntercepts(Map<String, dynamic> args) async {
    final interceptor = RequestBreakpointInterceptor.instance;
    return {
      'requests': interceptor.pendingRequestIds,
      'responses': interceptor.pendingResponseIds,
    };
  }

  Future<Map<String, dynamic>> releaseIntercept(Map<String, dynamic> args) async {
    final requestId = args['requestId']?.toString();
    if (requestId == null || requestId.isEmpty) {
      throw McpException.invalidParams('requestId is required');
    }
    final interceptor = RequestBreakpointInterceptor.instance;
    final phase = (args['phase']?.toString() ?? '').toLowerCase();
    final abort = args['abort'] == true;
    final isRequest = phase == 'request' || (phase.isEmpty && interceptor.pendingRequestIds.contains(requestId));
    if (isRequest) {
      if (!interceptor.pendingRequestIds.contains(requestId)) {
        throw McpException.app('not_found', 'pending request intercept not found');
      }
      if (abort) {
        interceptor.resumeRequest(requestId, null);
        auditLog.add('release_intercept', 'abort request $requestId');
        return {'ok': true, 'phase': 'request', 'aborted': true};
      }
      final original = await _requireRequest({'requestId': requestId});
      interceptor.resumeRequest(requestId, _applyRequestOverrides(original, args));
      auditLog.add('release_intercept', 'resume request $requestId');
      return {'ok': true, 'phase': 'request'};
    }
    if (!interceptor.pendingResponseIds.contains(requestId)) {
      throw McpException.app('not_found', 'pending intercept not found');
    }
    if (abort) {
      interceptor.resumeResponse(requestId, null);
      auditLog.add('release_intercept', 'abort response $requestId');
      return {'ok': true, 'phase': 'response', 'aborted': true};
    }
    final original = await _requireRequest({'requestId': requestId});
    final response = original.response;
    if (response == null) {
      throw McpException.app('not_found', 'response not available');
    }
    if (args['status'] is int) {
      response.status = HttpStatus.valueOf(args['status'] as int);
    }
    if (args['headers'] is Map) {
      response.headers.clear();
      _applyHeadersTo(response, args['headers']);
    }
    if (args.containsKey('body')) {
      response.body = args['body'] == null ? null : utf8.encode(args['body'].toString());
    }
    interceptor.resumeResponse(requestId, response);
    auditLog.add('release_intercept', 'resume response $requestId');
    return {'ok': true, 'phase': 'response'};
  }

  Future<Map<String, dynamic>> listRewriteRules(Map<String, dynamic> args) async {
    final manager = await RequestRewriteManager.instance;
    return {
      'enabled': manager.enabled,
      'items': [
        for (var i = 0; i < manager.rules.length; i++) {'index': i, ...manager.rules[i].toJson()},
      ],
    };
  }

  Future<Map<String, dynamic>> addRewriteRule(Map<String, dynamic> args) async {
    final url = args['url']?.toString();
    final typeName = args['type']?.toString();
    if (url == null || url.isEmpty || typeName == null || typeName.isEmpty) {
      throw McpException.invalidParams('url and type are required');
    }
    late final RuleType type;
    try {
      type = RuleType.fromName(typeName);
    } catch (_) {
      throw McpException.invalidParams('invalid rewrite type');
    }
    final manager = await RequestRewriteManager.instance;
    final rule = RequestRewriteRule(
      enabled: args['enabled'] is bool ? args['enabled'] as bool : true,
      name: args['name']?.toString(),
      url: url,
      type: type,
      method: _optionalMethod(args['method']),
    );
    final items = _rewriteItems(type, args);
    await manager.addRule(rule, items);
    await manager.flushRequestRewriteConfig();
    auditLog.add('add_rewrite_rule', '${type.name} $url');
    return {'ok': true, 'index': manager.rules.length - 1, 'rule': rule.toJson()};
  }

  Future<Map<String, dynamic>> removeRewriteRule(Map<String, dynamic> args) async {
    final manager = await RequestRewriteManager.instance;
    final index = _findIndex(manager.rules.length, args, (i) {
      final rule = manager.rules[i];
      return _matchNameOrUrl(args, name: rule.name, url: rule.url);
    });
    if (index == null) {
      throw McpException.app('not_found', 'rewrite rule not found');
    }
    final removed = manager.rules[index];
    await manager.removeIndex([index]);
    await manager.flushRequestRewriteConfig();
    auditLog.add('remove_rewrite_rule', removed.url);
    return {'ok': true, 'removed': removed.toJson()};
  }

  Future<Map<String, dynamic>> listScripts(Map<String, dynamic> args) async {
    final manager = await ScriptManager.instance;
    return {
      'enabled': manager.enabled,
      'items': [
        for (var i = 0; i < manager.list.length; i++)
          {
            'index': i,
            'name': manager.list[i].name,
            'url': manager.list[i].urls,
            'enabled': manager.list[i].enabled,
            'scriptPath': manager.list[i].scriptPath,
            'remoteUrl': manager.list[i].remoteUrl,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> getScriptContent(Map<String, dynamic> args) async {
    final manager = await ScriptManager.instance;
    final item = _findScript(manager, args);
    if (item == null) {
      throw McpException.app('not_found', 'script not found');
    }
    return {
      'name': item.name,
      'url': item.urls,
      'enabled': item.enabled,
      'script': await manager.getScript(item),
    };
  }

  Future<Map<String, dynamic>> createOrUpdateScript(Map<String, dynamic> args) async {
    final name = args['name']?.toString();
    final url = args['url']?.toString();
    final script = args['script']?.toString();
    if (name == null || name.isEmpty || url == null || url.isEmpty || script == null) {
      throw McpException.invalidParams('name, url and script are required');
    }
    final manager = await ScriptManager.instance;
    ScriptItem? existing;
    for (final item in manager.list) {
      if (item.name == name) {
        existing = item;
        break;
      }
    }
    if (existing != null) {
      existing.urls = url.contains(',') ? url.split(',').map((e) => e.trim()).toList() : [url];
      existing.urlRegs = null;
      if (args['enabled'] is bool) {
        existing.enabled = args['enabled'] as bool;
      }
      await manager.updateScript(existing, script);
      await manager.flushConfig();
      auditLog.add('create_or_update_script', 'update $name');
      return {'ok': true, 'updated': true, 'name': name};
    }
    final item = ScriptItem(args['enabled'] is bool ? args['enabled'] as bool : true, name, url);
    await manager.addScript(item, script);
    await manager.flushConfig();
    auditLog.add('create_or_update_script', 'create $name');
    return {'ok': true, 'created': true, 'name': name, 'index': manager.list.length - 1};
  }

  Future<Map<String, dynamic>> findSensitiveData(Map<String, dynamic> args) async {
    final request = await _requireRequest(args);
    final haystack = [
      request.requestUrl,
      request.headers.headerLines(),
      request.bodyAsString,
      request.response?.headers.headerLines() ?? '',
      request.response?.bodyAsString ?? '',
    ].join('\n');
    return {
      'requestId': request.requestId,
      'emails': _uniqueMatches(RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false), haystack),
      'phones': _uniqueMatches(RegExp(r'\+?\d[\d\- ]{8,}\d'), haystack),
      'jwts': _uniqueMatches(RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'), haystack),
      'tokens': _uniqueMatches(
        RegExp(r'''(api[_-]?key|secret|token|password|access[_-]?token)\s*[:=]\s*["']?([^\s"']+)''',
            caseSensitive: false),
        haystack,
        group: 2,
      ),
    };
  }

  Future<Map<String, dynamic>> analyzeAuth(Map<String, dynamic> args) async {
    final request = await _requireRequest(args);
    final authorization = request.headers.get('Authorization');
    final cookie = request.headers.get('Cookie');
    String? scheme;
    Map<String, dynamic>? jwt;
    if (authorization != null) {
      final parts = authorization.split(RegExp(r'\s+'));
      scheme = parts.isEmpty ? null : parts.first;
      if (parts.length > 1 && parts[1].startsWith('eyJ')) {
        jwt = _decodeJwt(parts[1]);
      }
    }
    return {
      'requestId': request.requestId,
      'hasAuthorization': authorization != null,
      'scheme': scheme,
      'hasCookie': cookie != null && cookie.isNotEmpty,
      'cookies': _parseCookieHeader(request.headers.getList('Cookie') ?? const []),
      'jwt': jwt,
      'setCookies': _parseSetCookie(request.response?.headers.getList('Set-Cookie') ?? const []),
    };
  }

  Future<Map<String, dynamic>> extractApiEndpoints(Map<String, dynamic> args) async {
    final matched = _filteredSession(args);
    final endpoints = <String, Map<String, dynamic>>{};
    for (final request in matched) {
      final uri = request.requestUri;
      final path = uri?.path ?? request.path;
      final key = '${request.method.name} $path';
      final item = endpoints.putIfAbsent(key, () {
        return {
          'method': request.method.name,
          'path': path,
          'host': uri?.host ?? request.hostAndPort?.host,
          'count': 0,
          'statuses': <int>{},
          'sampleRequestId': request.requestId,
        };
      });
      item['count'] = (item['count'] as int) + 1;
      final status = request.response?.status.code;
      if (status != null) {
        (item['statuses'] as Set<int>).add(status);
      }
    }
    return {
      'total': endpoints.length,
      'items': endpoints.values.map((item) {
        return {
          ...item,
          'statuses': (item['statuses'] as Set<int>).toList()..sort(),
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> exportHar(Map<String, dynamic> args) async {
    var requests = _filteredSession(args);
    final ids = args['requestIds'];
    if (ids is List && ids.isNotEmpty) {
      final wanted = ids.map((e) => e.toString()).toSet();
      requests = requests.where((request) => wanted.contains(request.requestId)).toList();
    }
    final title = args['title']?.toString() ?? 'MCP Export';
    final har = await Har.writeJson(requests, title: title);
    return {
      'count': requests.length,
      'title': title,
      'har': har,
    };
  }

  Future<Map<String, dynamic>> importHar(Map<String, dynamic> args) async {
    final har = args['har']?.toString();
    if (har == null || har.isEmpty) {
      throw McpException.invalidParams('har is required');
    }
    late final Map json;
    try {
      final decoded = jsonDecode(har);
      if (decoded is! Map) {
        throw const FormatException('HAR root must be an object');
      }
      json = decoded;
    } catch (e) {
      throw McpException.invalidParams('invalid HAR JSON: $e');
    }
    final log = json['log'] is Map ? json['log'] as Map : json;
    final entries = log['entries'];
    if (entries is! List) {
      throw McpException.invalidParams('HAR log.entries is required');
    }
    final requests = entries.whereType<Map>().map((entry) => Har.toRequest(Map<String, dynamic>.from(entry))).toList();
    final name = args['name']?.toString();
    final storage = await _history();
    if (storage == null) {
      throw McpException.app('unavailable', 'history storage is unavailable');
    }
    final item = await storage.addRequests(requests, name: name);
    auditLog.add('import_har', '${item.name} ${requests.length}');
    return {
      'ok': true,
      'name': item.name,
      'requestLength': item.requestLength,
      'path': item.path,
    };
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
    _applyHeadersTo(request, headers);
  }

  void _applyHeadersTo(HttpMessage message, dynamic headers) {
    if (headers is! Map) {
      return;
    }
    headers.forEach((key, value) {
      if (value == null) {
        return;
      }
      message.headers.set(key.toString(), value.toString());
    });
  }

  Future<HttpRequest> _requireRequest(Map<String, dynamic> args) async {
    final requestId = args['requestId']?.toString();
    if (requestId == null || requestId.isEmpty) {
      throw McpException.invalidParams('requestId is required');
    }
    final request = _findInSession(requestId) ?? await _findInHistoryCache(requestId);
    if (request == null) {
      throw McpException.app('not_found', 'requestId not found');
    }
    return request;
  }

  List<HttpRequest> _filteredSession(Map<String, dynamic> args) {
    final filter = TrafficFilter.fromArgs(args);
    return session.source.where(filter.matches).toList();
  }

  HttpRequest _applyRequestOverrides(HttpRequest original, Map<String, dynamic> args) {
    final overrideUrl = args['url']?.toString();
    final request = original.copy(uri: overrideUrl);
    if (args['method'] != null) {
      request.method = HttpMethod.valueOf(args['method'].toString());
    }
    if (args['headers'] is Map) {
      request.headers.clear();
      _applyHeaders(request, args['headers']);
    }
    if (args.containsKey('body')) {
      request.body = args['body'] == null ? null : utf8.encode(args['body'].toString());
    }
    return request;
  }

  HttpMethod? _optionalMethod(dynamic value) {
    if (value == null || value.toString().isEmpty) {
      return null;
    }
    try {
      return HttpMethod.valueOf(value.toString());
    } catch (_) {
      throw McpException.invalidParams('invalid HTTP method');
    }
  }

  int? _findIndex(int length, Map<String, dynamic> args, bool Function(int index) matches) {
    if (args['index'] is int) {
      final index = args['index'] as int;
      if (index >= 0 && index < length) {
        return index;
      }
      return null;
    }
    for (var i = 0; i < length; i++) {
      if (matches(i)) {
        return i;
      }
    }
    return null;
  }

  bool _matchNameOrUrl(Map<String, dynamic> args, {String? name, String? url}) {
    final wantName = args['name']?.toString();
    final wantUrl = args['url']?.toString();
    if (wantName != null && wantName.isNotEmpty && name == wantName) {
      return true;
    }
    if (wantUrl != null && wantUrl.isNotEmpty && url == wantUrl) {
      return true;
    }
    return false;
  }

  ScriptItem? _findScript(ScriptManager manager, Map<String, dynamic> args) {
    if (args['index'] is int) {
      final index = args['index'] as int;
      if (index >= 0 && index < manager.list.length) {
        return manager.list[index];
      }
      return null;
    }
    final name = args['name']?.toString();
    if (name == null || name.isEmpty) {
      throw McpException.invalidParams('index or name is required');
    }
    for (final item in manager.list) {
      if (item.name == name) {
        return item;
      }
    }
    return null;
  }

  List<RewriteItem> _rewriteItems(RuleType type, Map<String, dynamic> args) {
    switch (type) {
      case RuleType.redirect:
        return [RewriteItem(RewriteType.redirect, true)..redirectUrl = args['redirectUrl']?.toString() ?? ''];
      case RuleType.requestReplace:
        final items = <RewriteItem>[];
        if (args['headers'] is Map) {
          items.add(RewriteItem(RewriteType.replaceRequestHeader, true)
            ..headers = Map<String, String>.from(
              (args['headers'] as Map).map((key, value) => MapEntry(key.toString(), value.toString())),
            ));
        }
        if (args['body'] != null) {
          items.add(RewriteItem(RewriteType.replaceRequestBody, true)..body = args['body'].toString());
        }
        return items;
      case RuleType.responseReplace:
        final items = <RewriteItem>[];
        if (args['statusCode'] is int) {
          items.add(RewriteItem(RewriteType.replaceResponseStatus, true)..statusCode = args['statusCode'] as int);
        }
        if (args['headers'] is Map) {
          items.add(RewriteItem(RewriteType.replaceResponseHeader, true)
            ..headers = Map<String, String>.from(
              (args['headers'] as Map).map((key, value) => MapEntry(key.toString(), value.toString())),
            ));
        }
        if (args['body'] != null) {
          items.add(RewriteItem(RewriteType.replaceResponseBody, true)..body = args['body'].toString());
        }
        return items;
      case RuleType.requestUpdate:
      case RuleType.responseUpdate:
        if (args['body'] != null) {
          return [RewriteItem(RewriteType.updateBody, true)..value = args['body'].toString()];
        }
        return <RewriteItem>[];
    }
  }

  Map<String, String> _parseCookieHeader(List<String> values) {
    final cookies = <String, String>{};
    for (final value in values) {
      for (final part in value.split(';')) {
        final index = part.indexOf('=');
        if (index <= 0) {
          continue;
        }
        cookies[part.substring(0, index).trim()] = part.substring(index + 1).trim();
      }
    }
    return cookies;
  }

  List<Map<String, String>> _parseSetCookie(List<String> values) {
    return values.map((value) {
      final parts = value.split(';');
      final first = parts.isEmpty ? '' : parts.first;
      final index = first.indexOf('=');
      return {
        'name': index <= 0 ? first.trim() : first.substring(0, index).trim(),
        'value': index <= 0 ? '' : first.substring(index + 1).trim(),
        'raw': value,
      };
    }).toList();
  }

  Map<String, dynamic> _encodingHints(String text, String contentType) {
    final trimmed = text.trim();
    var jwt = false;
    var base64 = false;
    var json = false;
    if (RegExp(r'^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$').hasMatch(trimmed)) {
      jwt = true;
    }
    if (trimmed.length >= 16 && trimmed.length % 4 == 0 && RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(trimmed)) {
      base64 = true;
    }
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        jsonDecode(trimmed);
        json = true;
      } catch (_) {}
    }
    return {
      'contentType': contentType,
      'length': text.length,
      'looksJwt': jwt,
      'looksBase64': base64,
      'looksJson': json,
    };
  }

  Map<String, dynamic>? _decodeJwt(String token) {
    final parts = token.split('.');
    if (parts.length < 2) {
      return {'raw': token};
    }
    Map<String, dynamic>? payload;
    try {
      var segment = parts[1];
      final pad = segment.length % 4;
      if (pad != 0) {
        segment = segment.padRight(segment.length + (4 - pad), '=');
      }
      payload = jsonDecode(utf8.decode(base64Url.decode(segment))) as Map<String, dynamic>;
    } catch (_) {}
    return {'header': parts[0], 'payload': payload};
  }

  List<String> _uniqueMatches(RegExp pattern, String text, {int group = 0}) {
    final seen = <String>{};
    final items = <String>[];
    for (final match in pattern.allMatches(text)) {
      final value = match.group(group);
      if (value == null || value.isEmpty || !seen.add(value)) {
        continue;
      }
      items.add(value);
    }
    return items;
  }

  bool _mapEquals(Map left, Map right) {
    if (left.length != right.length) {
      return false;
    }
    for (final key in left.keys) {
      if (left[key].toString() != right[key].toString()) {
        return false;
      }
    }
    return true;
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
