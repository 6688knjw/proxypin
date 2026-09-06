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
    const expected = [
      'get_request_list',
      'get_request_detail',
      'get_request_stats',
      'get_domain_summary',
      'get_cookie_info',
      'compare_requests',
      'analyze_encrypted_content',
      'replay_request',
      'generate_code',
      'add_breakpoint',
      'remove_breakpoint',
      'list_breakpoints',
      'get_pending_intercepts',
      'release_intercept',
      'list_rewrite_rules',
      'add_rewrite_rule',
      'remove_rewrite_rule',
      'list_scripts',
      'get_script_content',
      'create_or_update_script',
      'find_sensitive_data',
      'analyze_auth',
      'extract_api_endpoints',
      'export_har',
      'import_har',
    ];
    expect(names, containsAll(expected));
    expect(names, containsAll([
      'send_request',
      'replay_request',
      'list_rules',
      'list_hosts',
      'add_host',
      'remove_host',
      'list_block_rules',
      'add_block_rule',
      'remove_block_rule',
      'list_map_rules',
      'add_map_rule',
      'remove_map_rule',
      'list_crypto_rules',
      'add_crypto_rule',
      'remove_crypto_rule',
      'list_network_conditions',
      'add_network_condition_rule',
      'remove_network_condition_rule',
      'list_environments',
      'set_environment_variable',
      'set_active_environment',
      'list_favorites',
      'add_favorite',
      'remove_favorite',
    ]));
    expect(names, isNot(contains('list_traffic')));
    expect(names, isNot(contains('get_traffic')));
    expect(names, isNot(contains('search_requests')));
    expect(names, isNot(contains('get_request_body')));
    expect(names, isNot(contains('execute_python')));
    expect(names, isNot(contains('execute_js')));
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
