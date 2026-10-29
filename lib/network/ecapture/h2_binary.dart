import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/h2/frame.dart';
import 'package:proxypin/network/http/h2/hpack/hpack.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';

class ECaptureH2Binary {
  static const _preface = [80, 82, 73, 32, 42, 32, 72, 84, 84, 80, 47, 50, 46, 48, 13, 10, 13, 10, 83, 77, 13, 10, 13, 10];

  static bool looksLike(List<int> payload) {
    if (payload.length < 9) return false;
    if (_hasPreface(payload)) return true;
    final length = (payload[0] << 16) | (payload[1] << 8) | payload[2];
    final type = payload[3];
    return (type == FrameType.data.index ||
            type == FrameType.headers.index ||
            type == FrameType.continuation.index) &&
        length >= 0 &&
        length <= payload.length - 9;
  }

  static HttpRequest? parseRequest(List<int> payload) {
    final decoded = _decode(payload);
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
    final request = HttpRequest(method, path, protocolVersion: 'HTTP/2');
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
    final decoded = _decode(payload);
    if (decoded == null) return null;
    final code = int.tryParse(decoded.headers[':status'] ?? '');
    if (code == null) return null;
    final response = HttpResponse(HttpStatus.valueOf(code), protocolVersion: 'HTTP/2');
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

  static _H2Message? _decode(List<int> payload, {bool headersRequired = true}) {
    var offset = _hasPreface(payload) ? _preface.length : 0;
    final decoder = HPackDecoder();
    final headers = <String, String>{};
    final body = <int>[];
    var streamId = 0;
    while (offset + 9 <= payload.length) {
      final length = (payload[offset] << 16) | (payload[offset + 1] << 8) | payload[offset + 2];
      final type = payload[offset + 3];
      final flags = payload[offset + 4];
      final id = ((payload[offset + 5] & 0x7f) << 24) |
          (payload[offset + 6] << 16) |
          (payload[offset + 7] << 8) |
          payload[offset + 8];
      offset += 9;
      if (offset + length > payload.length) break;
      final frame = payload.sublist(offset, offset + length);
      offset += length;
      if (id > 0) streamId = id;
      if (type == FrameType.headers.index || type == FrameType.continuation.index) {
        var block = frame;
        if (type == FrameType.headers.index) {
          var skip = 0;
          var pad = 0;
          if ((flags & 0x08) != 0) {
            if (block.isEmpty) continue;
            pad = block.first;
            skip += 1;
          }
          if ((flags & 0x20) != 0) skip += 5;
          if (skip + pad > block.length) continue;
          if (skip > 0 || pad > 0) {
            block = block.sublist(skip, block.length - pad);
          }
        }
        try {
          for (final header in decoder.decode(block)) {
            headers[header.nameString] = header.valueString;
          }
        } catch (_) {
          return null;
        }
      } else if (type == FrameType.data.index) {
        var data = frame;
        if ((flags & 0x08) != 0 && data.isNotEmpty) {
          final pad = data.first;
          if (pad + 1 <= data.length) {
            data = data.sublist(1, data.length - pad);
          }
        }
        body.addAll(data);
      }
    }
    if (headersRequired && headers.isEmpty) return null;
    if (headers.isEmpty && body.isEmpty) return null;
    return _H2Message(headers, body, streamId);
  }

  static bool _hasPreface(List<int> payload) {
    if (payload.length < _preface.length) return false;
    for (var i = 0; i < _preface.length; i++) {
      if (payload[i] != _preface[i]) return false;
    }
    return true;
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

class _H2Message {
  final Map<String, String> headers;
  final List<int> body;
  final int streamId;

  _H2Message(this.headers, this.body, this.streamId);
}
