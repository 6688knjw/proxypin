import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/mcp/mcp_models.dart';
import 'package:proxypin/network/mcp/mcp_tools.dart';
import 'package:proxypin/utils/listenable_list.dart';

HttpRequest _request({
  String url = 'https://example.com/api/users',
  HttpMethod method = HttpMethod.get,
  int? status,
  String body = '',
  String? requestId,
}) {
  final request = HttpRequest(method, url);
  if (requestId != null) {
    request.requestId = requestId;
  }
  request.body = utf8.encode(body);
  if (status != null) {
    request.response = HttpResponse(HttpStatus(status, 'OK'))
      ..request = request
      ..body = utf8.encode('{"ok":true}');
  }
  return request;
}

McpServices _services(ListenableList<HttpRequest> session, {int bodyLimit = 65536}) {
  final configuration = Configuration.fromJson({});
  return McpServices(
    session: session,
    proxyServer: () => ProxyServer(configuration),
    bodyLimit: () => bodyLimit,
    auditLog: McpAuditLog(),
  );
}

void main() {
  test('list_traffic filters and paginates current session', () async {
    final session = ListenableList<HttpRequest>([
      _request(url: 'https://example.com/api/users', method: HttpMethod.get, status: 200, requestId: 'r1'),
      _request(url: 'https://other.com/login', method: HttpMethod.post, status: 401, requestId: 'r2'),
      _request(url: 'https://example.com/api/orders', method: HttpMethod.get, status: 200, requestId: 'r3'),
    ]);
    final services = _services(session);
    final result = await services.listTraffic({'host': 'example.com', 'method': 'GET', 'limit': 1});
    expect(result['total'], 2);
    expect(result['items'].length, 1);
    expect(result['items'][0]['requestId'], 'r1');
  });

  test('get_traffic returns truncated body', () async {
    final request = _request(body: 'abcdefghijklmnopqrstuvwxyz', requestId: 'big');
    final session = ListenableList<HttpRequest>([request]);
    final services = _services(session, bodyLimit: 8);
    final result = await services.getTraffic({'requestId': 'big'});
    expect(result['requestBody'], 'abcdefgh');
    expect(result['requestBodyTruncated'], isTrue);
    expect(result['requestBodyOriginalLength'], 26);
  });

  test('get_traffic missing id returns not_found', () async {
    final services = _services(ListenableList<HttpRequest>());
    expect(
      () => services.getTraffic({'requestId': 'missing'}),
      throwsA(isA<McpException>().having((e) => e.data?['code'], 'code', 'not_found')),
    );
  });

  test('send_request rejects when proxy is not running', () async {
    final services = _services(ListenableList<HttpRequest>());
    expect(
      () => services.sendRequest({'method': 'GET', 'url': 'https://example.com/'}),
      throwsA(isA<McpException>().having((e) => e.data?['code'], 'code', 'proxy_not_running')),
    );
  });

  test('send_request rejects invalid url', () async {
    final services = _services(ListenableList<HttpRequest>());
    expect(
      () => services.sendRequest({'method': 'GET', 'url': 'not-a-url'}),
      throwsA(isA<McpException>().having((e) => e.data?['code'], 'code', 'invalid_url')),
    );
  });

  test('replay_request missing id returns not_found', () async {
    final services = _services(ListenableList<HttpRequest>());
    expect(
      () => services.replayRequest({'requestId': 'missing'}),
      throwsA(isA<McpException>().having((e) => e.data?['code'], 'code', 'not_found')),
    );
  });
}
