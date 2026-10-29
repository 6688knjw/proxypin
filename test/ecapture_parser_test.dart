import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/ecapture/event.dart';
import 'package:proxypin/network/ecapture/h2_binary.dart';
import 'package:proxypin/network/ecapture/h3_binary.dart';
import 'package:proxypin/network/ecapture/http_parser.dart';
import 'package:proxypin/network/ecapture/protobuf.dart';
import 'package:proxypin/network/http/h2/hpack/hpack.dart';
import 'package:proxypin/network/http/h3/qpack.dart';
import 'package:proxypin/network/http/http.dart';

void main() {
  group('ECaptureProtobuf', () {
    test('roundtrip event log entry', () {
      final event = ECaptureEvent(
        timestamp: 1710000000000,
        uuid: '1_1_curl_1_1_1.1.1.1:443',
        srcIp: '10.0.0.2',
        srcPort: 41234,
        dstIp: '1.1.1.1',
        dstPort: 443,
        pid: 1234,
        pname: 'curl',
        type: ECaptureEvent.typeHttp1Request,
        length: 18,
        payload: utf8.encode('GET / HTTP/1.1\r\n\r\n'),
        captureFormat: ECaptureEvent.formatText,
        streamId: '1',
        sequence: 9,
      );
      final encoded = ECaptureProtobuf.encode(ECaptureLogEntry(
        logType: ECaptureLogEntry.logEvent,
        event: event,
      ));
      final decoded = ECaptureProtobuf.decode(encoded);
      expect(decoded.logType, ECaptureLogEntry.logEvent);
      expect(decoded.event?.uuid, event.uuid);
      expect(decoded.event?.type, ECaptureEvent.typeHttp1Request);
      expect(utf8.decode(decoded.event!.payload), 'GET / HTTP/1.1\r\n\r\n');
      expect(decoded.event?.streamId, '1');
      expect(decoded.event?.sequence, 9);
    });

    test('roundtrip HTTP/3 event types', () {
      for (final type in [ECaptureEvent.typeHttp3Request, ECaptureEvent.typeHttp3Response]) {
        final encoded = ECaptureProtobuf.encode(ECaptureLogEntry(
          logType: ECaptureLogEntry.logEvent,
          event: ECaptureEvent(uuid: 'h3', type: type, payload: [1, 2, 3]),
        ));
        final decoded = ECaptureProtobuf.decode(encoded).event!;
        expect(decoded.type, type);
        expect(decoded.isHttp3, isTrue);
        expect(decoded.payload, [1, 2, 3]);
      }
    });
  });

  group('ECaptureHttpParser', () {
    final parser = ECaptureHttpParser();

    test('parses HTTP/1 request and response', () {
      final reqEvent = ECaptureEvent(
        uuid: 'conn-1',
        dstIp: 'example.com',
        dstPort: 443,
        pname: 'chrome',
        type: ECaptureEvent.typeHttp1Request,
        payload: utf8.encode(
          'POST /v1/login HTTP/1.1\r\n'
          'Host: example.com\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 16\r\n'
          '\r\n'
          '{"user":"a"}    ',
        ),
      );
      final request = parser.parseRequest(reqEvent)!;
      expect(request.method, HttpMethod.post);
      expect(request.uri, '/v1/login');
      expect(request.headers.host, 'example.com');
      expect(request.bodyAsString.contains('user'), isTrue);

      parser.attachMeta(request, reqEvent);
      request.hostAndPort = parser.hostAndPort(reqEvent, request: request);
      expect(request.requestUrl, 'https://example.com/v1/login');
      expect(request.processInfo, isNull);
      request.processInfo = parser.processInfo(reqEvent);
      expect(request.processInfo?.name, 'chrome');

      final respEvent = ECaptureEvent(
        uuid: 'conn-1',
        type: ECaptureEvent.typeHttp1Response,
        payload: utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 11\r\n'
          '\r\n'
          '{"ok":true}',
        ),
      );
      final response = parser.parseResponse(respEvent)!;
      expect(response.status.code, 200);
      expect(response.bodyAsString, '{"ok":true}');
    });

    test('parses HTTP/2 header-field dump', () {
      final event = ECaptureEvent(
        uuid: 'h2-1',
        dstIp: 'google.com',
        dstPort: 443,
        type: ECaptureEvent.typeHttp2Request,
        payload: utf8.encode(
          'UUID:h2-1, Name:HTTP2Request, Type:2, Length:304\n'
          'header field ":method" = "GET"\n'
          'header field ":path" = "/complete/search"\n'
          'header field ":authority" = "google.com"\n'
          'header field ":scheme" = "https"\n'
          'header field "user-agent" = "curl/8.0"\n',
        ),
      );
      final request = parser.parseRequest(event)!;
      expect(request.method, HttpMethod.get);
      expect(request.uri, '/complete/search');
      expect(request.protocolVersion, 'HTTP/2');
      expect(request.headers.host, 'google.com');
      expect(request.hostAndPort?.host, 'google.com');
      expect(request.hostAndPort?.port, 443);
    });

    test('parses HTTP/2 response status dump', () {
      final event = ECaptureEvent(
        type: ECaptureEvent.typeHttp2Response,
        payload: utf8.encode(
          'header field ":status" = "204"\n'
          'header field "server" = "nginx"\n',
        ),
      );
      final response = parser.parseResponse(event)!;
      expect(response.status.code, 204);
      expect(response.headers.get('server'), 'nginx');
    });

    test('pairs request and response after stripping uuid direction', () {
      final req = ECaptureEvent(
        uuid: '233851_233851_curl_5_1_172.16.71.1:51837',
        pid: 233851,
        srcPort: 51837,
        dstPort: 443,
        streamId: '1',
        type: ECaptureEvent.typeHttp2Request,
      );
      final resp = ECaptureEvent(
        uuid: '233851_233851_curl_5_0_172.16.71.1:51837',
        pid: 233851,
        srcPort: 51837,
        dstPort: 443,
        streamId: '1',
        type: ECaptureEvent.typeHttp2Response,
      );
      expect(req.pairKey, resp.pairKey);
      expect(req.isRequest, isTrue);
      expect(resp.isResponse, isTrue);

      final swapped = ECaptureEvent(
        uuid: '233851_233851_curl_5_0_172.16.71.1:51837',
        pid: 233851,
        srcPort: 443,
        dstPort: 51837,
        streamId: '1',
        type: ECaptureEvent.typeHttp2Response,
      );
      expect(req.pairKey, swapped.pairKey);
      expect(req.pairKey, contains('|1|233851'));
    });

    test('attachMeta uses pairKey as requestId', () {
      final event = ECaptureEvent(
        uuid: '233851_233851_curl_5_1_172.16.71.1:51837',
        pid: 233851,
        streamId: '3',
        type: ECaptureEvent.typeHttp2Request,
        payload: utf8.encode('GET / HTTP/1.1\r\nHost: a\r\n\r\n'),
      );
      final request = parser.parseRequest(event)!;
      parser.attachMeta(request, event);
      expect(request.requestId, event.pairKey);
      expect(request.requestId.contains('_1_'), isFalse);
    });

    test('parses HTTP/2 binary HEADERS frame', () {
      final encoder = HPackEncoder();
      final block = encoder.encode([
        Header.ascii(':method', 'GET'),
        Header.ascii(':path', '/search'),
        Header.ascii(':scheme', 'https'),
        Header.ascii(':authority', 'example.com'),
        Header.ascii('user-agent', 'curl/8.0'),
      ]);
      final payload = _h2Frame(1, 0x05, 1, block);
      final event = ECaptureEvent(
        type: ECaptureEvent.typeHttp2Request,
        dstIp: 'example.com',
        dstPort: 443,
        payload: payload,
      );
      final request = parser.parseRequest(event)!;
      expect(request.method, HttpMethod.get);
      expect(request.uri, '/search');
      expect(request.protocolVersion, 'HTTP/2');
      expect(request.headers.host, 'example.com');
      expect(ECaptureH2Binary.looksLike(payload), isTrue);
    });

    test('parses HTTP/3 QPACK headers', () {
      final encoder = QPackEncoder();
      final block = encoder.encodeFieldSection([
        Header.ascii(':method', 'POST'),
        Header.ascii(':path', '/v1/login'),
        Header.ascii(':scheme', 'https'),
        Header.ascii(':authority', 'api.example.com'),
        Header.ascii('content-type', 'application/json'),
      ]);
      final payload = [..._quicVarint(0x01), ..._quicVarint(block.length), ...block];
      final event = ECaptureEvent(
        type: ECaptureEvent.typeHttp3Request,
        dstPort: 443,
        payload: payload,
      );
      final request = parser.parseRequest(event)!;
      expect(request.method, HttpMethod.post);
      expect(request.uri, '/v1/login');
      expect(request.protocolVersion, 'HTTP/3');
      expect(request.headers.host, 'api.example.com');
      expect(request.headers.get('content-type'), 'application/json');
      expect(ECaptureH3Binary.looksLike(payload), isTrue);
    });

    test('extracts HTTP/2 DATA body without headers', () {
      final payload = _h2Frame(0, 0x01, 1, utf8.encode('hello'));
      expect(ECaptureH2Binary.extractBody(payload), utf8.encode('hello'));
      expect(parser.parseRequest(ECaptureEvent(
        type: ECaptureEvent.typeHttp2Request,
        payload: payload,
      )), isNull);
    });

    test('extracts HTTP/3 DATA body without headers', () {
      final payload = [..._quicVarint(0x00), ..._quicVarint(5), ...utf8.encode('hello')];
      expect(ECaptureH3Binary.extractBody(payload), utf8.encode('hello'));
      expect(parser.parseRequest(ECaptureEvent(
        type: ECaptureEvent.typeUnknown,
        payload: payload,
      )), isNull);
      expect(parser.parseResponse(ECaptureEvent(
        type: ECaptureEvent.typeUnknown,
        payload: payload,
      )), isNull);
    });

    test('parses HTTP/3 response status', () {
      final encoder = QPackEncoder();
      final block = encoder.encodeFieldSection([
        Header.ascii(':status', '200'),
        Header.ascii('server', 'quic-go'),
      ]);
      final payload = [..._quicVarint(0x01), ..._quicVarint(block.length), ...block];
      final event = ECaptureEvent(
        type: ECaptureEvent.typeHttp3Response,
        payload: payload,
      );
      final response = parser.parseResponse(event)!;
      expect(response.status.code, 200);
      expect(response.protocolVersion, 'HTTP/3');
      expect(response.headers.get('server'), 'quic-go');
    });
  });

  group('QPack', () {
    test('roundtrip static and literal headers', () {
      final headers = [
        Header.ascii(':method', 'GET'),
        Header.ascii(':path', '/index.html'),
        Header.ascii('x-custom', 'hello'),
      ];
      final encoded = QPackEncoder().encodeFieldSection(headers);
      final decoded = QPackDecoder().decodeFieldSection(encoded);
      expect(decoded.map((h) => '${h.nameString}=${h.valueString}').toList(), [
        ':method=GET',
        ':path=/index.html',
        'x-custom=hello',
      ]);
      expect(encoded[0], 0);
      expect(encoded[1], 0);
      expect(encoded[2] & 0xc0, 0xc0);
      expect(encoded[3] & 0xf0, 0x50);
    });
  });
}

List<int> _h2Frame(int type, int flags, int streamId, List<int> payload) {
  return [
    (payload.length >> 16) & 0xff,
    (payload.length >> 8) & 0xff,
    payload.length & 0xff,
    type,
    flags,
    (streamId >> 24) & 0x7f,
    (streamId >> 16) & 0xff,
    (streamId >> 8) & 0xff,
    streamId & 0xff,
    ...payload,
  ];
}

List<int> _quicVarint(int value) {
  if (value < 64) return [value];
  if (value < 16384) return [0x40 | ((value >> 8) & 0x3f), value & 0xff];
  throw ArgumentError('varint too large for test helper: $value');
}
