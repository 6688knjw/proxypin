import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/h3/qpack.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';

class ECaptureH3Binary {
  static const _headers = 0x01;
  static const _data = 0x00;

  static bool looksLike(List<int> payload) {
    if (payload.isEmpty) return false;
    try {
      final reader = _VarIntReader(payload);
      final type = reader.read();
      final length = reader.read();
      return type == _headers && length >= 0 && reader.offset + length <= payload.length;
    } catch (_) {
      return false;
    }
  }

  static HttpRequest? parseRequest(List<int> payload) {
    final decoded = _decode(payload) ?? _decodeRaw(payload);
    if (decoded == null) return null;
    final methodName = decoded.headers[':method'];
    final path = decoded.headers[':path'] ?? '/';
    if (methodName == null) return null;
    HttpMethod method;
    try {
      method = HttpMethod.valueOf(methodName);
    } catch (_) {
      return null;
    }
    final request = HttpRequest(method, path, protocolVersion: 'HTTP/3');
    _applyHeaders(request.headers, decoded.headers);
    if (decoded.body.isNotEmpty) request.body = decoded.body;
    request.streamId = decoded.streamId;
    final authority = decoded.headers[':authority'];
    final scheme = decoded.headers[':scheme'] ?? 'https';
    if (authority != null && authority.isNotEmpty) {
      request.hostAndPort = HostAndPort.of('$scheme://$authority');
    }
    return request;
  }

  static HttpResponse? parseResponse(List<int> payload) {
    final decoded = _decode(payload) ?? _decodeRaw(payload);
    if (decoded == null) return null;
    final code = int.tryParse(decoded.headers[':status'] ?? '');
    if (code == null) return null;
    final response = HttpResponse(HttpStatus.valueOf(code), protocolVersion: 'HTTP/3');
    _applyHeaders(response.headers, decoded.headers);
    if (decoded.body.isNotEmpty) response.body = decoded.body;
    response.streamId = decoded.streamId;
    return response;
  }

  static List<int>? extractBody(List<int> payload) {
    final decoded = _decode(payload, headersRequired: false);
    if (decoded == null || decoded.body.isEmpty) return null;
    return decoded.body;
  }

  static _H3Message? _decode(List<int> payload, {bool headersRequired = true}) {
    final reader = _VarIntReader(payload);
    final headers = <String, String>{};
    final body = <int>[];
    final decoder = QPackDecoder();
    try {
      while (reader.hasMore) {
        final type = reader.read();
        final length = reader.read();
        final frame = reader.readBytes(length);
        if (type == _headers) {
          for (final header in decoder.decodeFieldSection(frame)) {
            headers[header.nameString] = header.valueString;
          }
        } else if (type == _data) {
          body.addAll(frame);
        }
      }
    } catch (_) {
      if (headers.isEmpty && body.isEmpty) return null;
    }
    if (headersRequired && headers.isEmpty) return null;
    if (headers.isEmpty && body.isEmpty) return null;
    return _H3Message(headers, body, 0);
  }

  static _H3Message? _decodeRaw(List<int> payload) {
    try {
      final headers = <String, String>{};
      for (final header in QPackDecoder().decodeFieldSection(payload)) {
        headers[header.nameString] = header.valueString;
      }
      if (headers.isEmpty) return null;
      return _H3Message(headers, const [], 0);
    } catch (_) {
      return null;
    }
  }

  static void _applyHeaders(HttpHeaders headers, Map<String, String> fields) {
    fields.forEach((name, value) {
      if (name == ':authority') {
        headers.set(HttpHeaders.HOST, value);
        return;
      }
      if (name.startsWith(':')) return;
      headers.add(name, value);
    });
  }
}

class _H3Message {
  final Map<String, String> headers;
  final List<int> body;
  final int streamId;

  _H3Message(this.headers, this.body, this.streamId);
}

class _VarIntReader {
  final List<int> data;
  int offset = 0;

  _VarIntReader(this.data);

  bool get hasMore => offset < data.length;

  int read() {
    if (offset >= data.length) throw RangeError('h3 varint truncated');
    final first = data[offset];
    final prefix = first >> 6;
    final len = 1 << prefix;
    if (offset + len > data.length) throw RangeError('h3 varint truncated');
    var value = first & 0x3f;
    for (var i = 1; i < len; i++) {
      value = (value << 8) | data[offset + i];
    }
    offset += len;
    return value;
  }

  List<int> readBytes(int length) {
    if (offset + length > data.length) throw RangeError('h3 frame truncated');
    final out = data.sublist(offset, offset + length);
    offset += length;
    return out;
  }
}
