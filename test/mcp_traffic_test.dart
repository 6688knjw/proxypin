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

  test('get_request_list aliases list_traffic', () async {
    final session = ListenableList<HttpRequest>([
      _request(url: 'https://example.com/api', status: 200, requestId: 'a'),
    ]);
    final services = _services(session);
    final result = await services.getRequestList({});
    expect(result['total'], 1);
    expect(result['items'][0]['requestId'], 'a');
  });

  test('get_request_stats aggregates methods and hosts', () async {
    final session = ListenableList<HttpRequest>([
      _request(url: 'https://example.com/a', method: HttpMethod.get, status: 200, requestId: 'a'),
      _request(url: 'https://example.com/b', method: HttpMethod.post, status: 201, requestId: 'b'),
      _request(url: 'https://other.com/c', method: HttpMethod.get, status: 404, requestId: 'c'),
    ]);
    final result = await _services(session).getRequestStats({});
    expect(result['total'], 3);
    expect(result['methods']['GET'], 2);
    expect(result['hosts']['example.com'], 2);
  });

  test('get_cookie_info parses request cookies', () async {
    final request = _request(url: 'https://example.com/me', requestId: 'cookie');
    request.headers.set('Cookie', 'sid=abc; theme=dark');
    request.response = HttpResponse(HttpStatus.ok)
      ..request = request
      ..headers.add('Set-Cookie', 'sid=abc; Path=/');
    final result = await _services(ListenableList([request])).getCookieInfo({'requestId': 'cookie'});
    expect(result['requestCookies']['sid'], 'abc');
    expect(result['setCookies'][0]['name'], 'sid');
  });

  test('compare_requests reports url and method diffs', () async {
    final left = _request(url: 'https://example.com/a', method: HttpMethod.get, status: 200, requestId: 'l');
    final right = _request(url: 'https://example.com/b', method: HttpMethod.post, status: 200, requestId: 'r');
    final result = await _services(ListenableList([left, right])).compareRequests({
      'requestId': 'l',
      'otherRequestId': 'r',
    });
    expect(result['diff']['url'], isTrue);
    expect(result['diff']['method'], isTrue);
    expect(result['diff']['status'], isFalse);
  });

  test('generate_code returns curl', () async {
    final request = _request(url: 'https://example.com/api', requestId: 'g');
    final result = await _services(ListenableList([request])).generateCode({'requestId': 'g', 'format': 'curl'});
    expect(result['code'], contains("curl -X GET 'https://example.com/api'"));
  });

  test('find_sensitive_data extracts email and jwt', () async {
    final request = _request(
      url: 'https://example.com/login',
      body: 'email=user@example.com&token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMifQ.abc',
      requestId: 's',
    );
    final result = await _services(ListenableList([request])).findSensitiveData({'requestId': 's'});
    expect(result['emails'], contains('user@example.com'));
    expect(result['jwts'], isNotEmpty);
  });

  test('analyze_auth reports bearer scheme', () async {
    final request = _request(url: 'https://example.com/me', requestId: 'auth');
    request.headers.set('Authorization', 'Bearer abc.def.ghi');
    final result = await _services(ListenableList([request])).analyzeAuth({'requestId': 'auth'});
    expect(result['hasAuthorization'], isTrue);
    expect(result['scheme'], 'Bearer');
  });

  test('extract_api_endpoints groups by method and path', () async {
    final session = ListenableList<HttpRequest>([
      _request(url: 'https://example.com/api/users', method: HttpMethod.get, status: 200, requestId: 'e1'),
      _request(url: 'https://example.com/api/users?id=1', method: HttpMethod.get, status: 200, requestId: 'e2'),
    ]);
    final result = await _services(session).extractApiEndpoints({});
    expect(result['total'], 1);
    expect(result['items'][0]['path'], '/api/users');
    expect(result['items'][0]['count'], 2);
  });
}
