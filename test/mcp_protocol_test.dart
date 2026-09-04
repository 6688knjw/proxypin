import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/mcp/mcp_models.dart';
import 'package:proxypin/network/mcp/mcp_protocol.dart';
import 'package:proxypin/network/mcp/mcp_tools.dart';
import 'package:proxypin/utils/listenable_list.dart';

McpServices _services({ListenableList<HttpRequest>? session, ProxyServer? server}) {
  final configuration = Configuration.fromJson({});
  final proxy = server ?? ProxyServer(configuration);
  return McpServices(
    session: session ?? ListenableList<HttpRequest>(),
    proxyServer: () => proxy,
    bodyLimit: () => configuration.mcpBodyLimit,
    auditLog: McpAuditLog(),
  );
}

void main() {
  test('initialize returns serverInfo and capabilities', () async {
    final handler = McpJsonRpcHandler(_services().buildRegistry());
    final response = await handler.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {},
    });
    expect(response!['result']['serverInfo']['name'], 'proxypin-mcp');
    expect(response['result']['capabilities']['tools'], isNotNull);
  });

  test('tools/list excludes code execution tools', () async {
    final handler = McpJsonRpcHandler(_services().buildRegistry());
    final response = await handler.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final names = (response!['result']['tools'] as List).map((tool) => tool['name']).toList();
    expect(names, containsAll(['list_traffic', 'get_traffic', 'send_request', 'replay_request', 'list_rules']));
    expect(names, isNot(contains('execute_python')));
    expect(names, isNot(contains('execute_js')));
    expect(names, isNot(contains('update_rule')));
  });

  test('unknown method returns method not found', () async {
    final handler = McpJsonRpcHandler(_services().buildRegistry());
    final response = await handler.handle({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'execute_python',
    });
    expect(response!['error']['code'], -32601);
  });

  test('auth helper rejects missing or wrong token', () {
    expect(mcpTokenMatches('secret'), isFalse);
    expect(mcpTokenMatches('secret', authorization: 'Bearer wrong'), isFalse);
    expect(mcpTokenMatches('secret', authorization: 'Bearer secret'), isTrue);
    expect(mcpTokenMatches('secret', queryToken: 'secret'), isTrue);
    expect(mcpTokenMatches(''), isFalse);
  });
}
