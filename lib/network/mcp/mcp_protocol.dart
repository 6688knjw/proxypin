import 'dart:convert';

import 'package:proxypin/network/mcp/mcp_models.dart';
import 'package:proxypin/network/mcp/mcp_tools.dart';

bool mcpTokenMatches(String expected, {String? authorization, String? queryToken}) {
  if (expected.isEmpty) {
    return false;
  }
  String? provided = queryToken;
  if (authorization != null && authorization.toLowerCase().startsWith('bearer ')) {
    provided = authorization.substring(7).trim();
  }
  return provided != null && provided == expected;
}

class McpJsonRpcHandler {
  static const protocolVersion = '2024-11-05';
  static const serverName = 'proxypin-mcp';
  static const serverVersion = '1.0.0';

  final McpToolRegistry registry;

  McpJsonRpcHandler(this.registry);

  Future<Map<String, dynamic>?> handle(Map<String, dynamic> message) async {
    if (message['jsonrpc'] != '2.0') {
      return _error(message['id'], -32600, 'Invalid Request');
    }

    final method = message['method']?.toString();
    final id = message['id'];
    if (method == null || method.isEmpty) {
      return _error(id, -32600, 'Invalid Request');
    }

    if (id == null) {
      return null;
    }

    try {
      final result = await _dispatch(method, message['params']);
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on McpException catch (e) {
      return {'jsonrpc': '2.0', 'id': id, 'error': e.toJsonRpcError()};
    } catch (e) {
      return _error(id, -32603, e.toString());
    }
  }

  Future<dynamic> handleRaw(String body) async {
    final decoded = jsonDecode(body);
    if (decoded is List) {
      final responses = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final response = await handle(item);
          if (response != null) {
            responses.add(response);
          }
        }
      }
      return responses;
    }
    if (decoded is Map<String, dynamic>) {
      return handle(decoded);
    }
    return _error(null, -32700, 'Parse error');
  }

  Future<Map<String, dynamic>> _dispatch(String method, dynamic params) async {
    final args = params is Map<String, dynamic> ? params : <String, dynamic>{};
    switch (method) {
      case 'initialize':
        return {
          'protocolVersion': protocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
            'resources': {'subscribe': false, 'listChanged': false},
          },
          'serverInfo': {'name': serverName, 'version': serverVersion},
        };
      case 'notifications/initialized':
        return {};
      case 'ping':
        return {};
      case 'tools/list':
        return {'tools': registry.listTools()};
      case 'tools/call':
        final name = args['name']?.toString();
        if (name == null || name.isEmpty) {
          throw McpException.invalidParams('tool name is required');
        }
        final toolArgs = args['arguments'] is Map<String, dynamic>
            ? args['arguments'] as Map<String, dynamic>
            : <String, dynamic>{};
        final result = await registry.call(name, toolArgs);
        return {
          'content': [
            {'type': 'text', 'text': jsonEncode(result)}
          ],
          'structuredContent': result,
        };
      case 'resources/list':
        return {
          'resources': [
            {
              'uri': 'proxypin://traffic',
              'name': 'Captured session traffic',
              'mimeType': 'application/json',
            },
            {
              'uri': 'proxypin://proxy-status',
              'name': 'Proxy status',
              'mimeType': 'application/json',
            },
          ]
        };
      case 'resources/read':
        final uri = args['uri']?.toString();
        if (uri == 'proxypin://traffic') {
          final result = await registry.call('list_traffic', {'limit': 50});
          return {
            'contents': [
              {'uri': uri, 'mimeType': 'application/json', 'text': jsonEncode(result)}
            ]
          };
        }
        if (uri == 'proxypin://proxy-status') {
          final result = await registry.call('get_proxy_status', {});
          return {
            'contents': [
              {'uri': uri, 'mimeType': 'application/json', 'text': jsonEncode(result)}
            ]
          };
        }
        throw McpException.app('not_found', 'resource not found');
      default:
        throw McpException.methodNotFound(method);
    }
  }

  Map<String, dynamic> _error(dynamic id, int code, String message) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
  }
}
