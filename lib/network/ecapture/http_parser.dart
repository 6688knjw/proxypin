import 'dart:convert';

import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/ecapture/event.dart';
import 'package:proxypin/network/ecapture/h2_binary.dart';
import 'package:proxypin/network/ecapture/h3_binary.dart';
import 'package:proxypin/network/http/codec.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';
import 'package:proxypin/network/util/byte_buf.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/process_info.dart';

class ECaptureHttpParser {
  HttpRequest? parseRequest(ECaptureEvent event) {
    if (event.payload.isEmpty) return null;
    try {
      if (event.isHttp3) {
        return _parseHttp3Request(event) ?? _parseHttp2Request(event);
      }
      if (event.isHttp2) {
        return _parseHttp2Request(event) ?? _parseHttp3Request(event);
      }
      return _parseHttp1Request(event) ?? _parseHttp2Request(event) ?? _parseHttp3Request(event);
    } catch (e, st) {
      logger.d('[eCapture] parse request failed: $e', stackTrace: st);
      return null;
    }
  }

  HttpResponse? parseResponse(ECaptureEvent event) {
    if (event.payload.isEmpty) return null;
    try {
      if (event.isHttp3) {
        return _parseHttp3Response(event) ?? _parseHttp2Response(event);
      }
      if (event.isHttp2) {
        return _parseHttp2Response(event) ?? _parseHttp3Response(event);
      }
      return _parseHttp1Response(event) ?? _parseHttp2Response(event) ?? _parseHttp3Response(event);
    } catch (e, st) {
      logger.d('[eCapture] parse response failed: $e', stackTrace: st);
      return null;
    }
  }

  List<int>? extractBody(ECaptureEvent event) {
    if (event.payload.isEmpty) return null;
    if (event.isHttp3) {
      return ECaptureH3Binary.extractBody(event.payload) ?? ECaptureH2Binary.extractBody(event.payload);
    }
    if (event.isHttp2) {
      return ECaptureH2Binary.extractBody(event.payload) ?? ECaptureH3Binary.extractBody(event.payload);
    }
    return ECaptureH2Binary.extractBody(event.payload) ?? ECaptureH3Binary.extractBody(event.payload);
  }

  void attachMeta(HttpMessage message, ECaptureEvent event) {
    message.remoteHost = event.dstIp;
    message.remotePort = event.dstPort;
    message.requestId = event.pairKey;
    if (event.timestamp > 0) {
      final time = DateTime.fromMillisecondsSinceEpoch(
        event.timestamp > 1000000000000 ? event.timestamp : event.timestamp * 1000,
      );
      if (message is HttpRequest) {
        message.requestTime = time;
      } else if (message is HttpResponse) {
        message.responseTime = time;
      }
    }
  }

  ProcessInfo processInfo(ECaptureEvent event) {
    final name = event.pname.isEmpty ? 'pid-${event.pid}' : event.pname;
    return ProcessInfo(name, name, '', os: 'android');
  }

  HostAndPort hostAndPort(ECaptureEvent event, {HttpRequest? request}) {
    final headerHost = request?.headers.host;
    var host = event.dstIp;
    var port = event.dstPort == 0 ? 443 : event.dstPort;
    if (headerHost != null && headerHost.isNotEmpty) {
      final parsed = HostAndPort.of(headerHost, ssl: port == 443);
      host = parsed.host;
      if (headerHost.contains(':')) port = parsed.port;
    }
    final scheme = (port == 443 || (request?.headers.get('X-Forwarded-Proto') == 'https'))
        ? HostAndPort.httpsScheme
        : (port == 80 ? HostAndPort.httpScheme : HostAndPort.httpsScheme);
    return HostAndPort(scheme, host, port);
  }

  HttpRequest? _parseHttp1Request(ECaptureEvent event) {
    final codec = HttpRequestCodec();
    final result = codec.decode(ChannelContext(), ByteBuf(event.payload));
    if (result.isDone && result.data != null) {
      return result.data;
    }
    if (result.data != null) {
      result.data!.body ??= [];
      return result.data;
    }
    return _parseHttp1RequestLoose(event.payload);
  }

  HttpResponse? _parseHttp1Response(ECaptureEvent event) {
    final codec = HttpResponseCodec();
    final result = codec.decode(ChannelContext(), ByteBuf(event.payload));
    if (result.isDone && result.data != null) {
      return result.data;
    }
    if (result.data != null) {
      result.data!.body ??= [];
      return result.data;
    }
    return _parseHttp1ResponseLoose(event.payload);
  }

  HttpRequest? _parseHttp1RequestLoose(List<int> payload) {
    final text = _payloadText(payload);
    final split = _splitHeadersBody(text);
    if (split == null) return null;
    final lines = split.$1.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return null;
    final first = lines.first.split(RegExp(r'\s+'));
    if (first.length < 2) return null;
    HttpMethod method;
    try {
      method = HttpMethod.valueOf(first[0]);
    } catch (_) {
      return null;
    }
    final request = HttpRequest(method, first[1], protocolVersion: first.length > 2 ? first[2] : 'HTTP/1.1');
    _applyHeaders(request.headers, lines.skip(1));
    if (split.$2.isNotEmpty) request.body = utf8.encode(split.$2);
    return request;
  }

  HttpResponse? _parseHttp1ResponseLoose(List<int> payload) {
    final text = _payloadText(payload);
    final split = _splitHeadersBody(text);
    if (split == null) return null;
    final lines = split.$1.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return null;
    final first = lines.first.split(RegExp(r'\s+'));
    if (first.length < 2) return null;
    final code = int.tryParse(first[1]);
    if (code == null) return null;
    final reason = first.length > 2 ? first.sublist(2).join(' ') : '';
    final response = HttpResponse(HttpStatus(code, reason), protocolVersion: first[0]);
    _applyHeaders(response.headers, lines.skip(1));
    if (split.$2.isNotEmpty) response.body = utf8.encode(split.$2);
    return response;
  }

  HttpRequest? _parseHttp2Request(ECaptureEvent event) {
    if (ECaptureH2Binary.looksLike(event.payload)) {
      final binary = ECaptureH2Binary.parseRequest(event.payload);
      if (binary != null) return binary;
    }
    final fields = _http2Fields(event.payload);
    if (fields == null) return null;
    final methodName = fields[':method'];
    final path = fields[':path'] ?? '/';
    if (methodName == null) return null;
    HttpMethod method;
    try {
      method = HttpMethod.valueOf(methodName);
    } catch (_) {
      return null;
    }
    final request = HttpRequest(method, path, protocolVersion: 'HTTP/2');
    _applyPseudoAndHeaders(request.headers, fields);
    final body = fields['_body'];
    if (body != null && body.isNotEmpty) request.body = utf8.encode(body);
    final authority = fields[':authority'];
    final scheme = fields[':scheme'] ?? 'https';
    if (authority != null && authority.isNotEmpty) {
      request.hostAndPort = HostAndPort.of('$scheme://$authority');
    }
    return request;
  }

  HttpResponse? _parseHttp2Response(ECaptureEvent event) {
    if (ECaptureH2Binary.looksLike(event.payload)) {
      final binary = ECaptureH2Binary.parseResponse(event.payload);
      if (binary != null) return binary;
    }
    final fields = _http2Fields(event.payload);
    if (fields == null) return null;
    final statusText = fields[':status'];
    final code = int.tryParse(statusText ?? '');
    if (code == null) return null;
    final response = HttpResponse(HttpStatus.valueOf(code), protocolVersion: 'HTTP/2');
    _applyPseudoAndHeaders(response.headers, fields);
    final body = fields['_body'];
    if (body != null && body.isNotEmpty) response.body = utf8.encode(body);
    return response;
  }

  HttpRequest? _parseHttp3Request(ECaptureEvent event) {
    final binary = ECaptureH3Binary.parseRequest(event.payload);
    if (binary != null) return binary;
    final fields = _http2Fields(event.payload);
    if (fields == null) return null;
    final methodName = fields[':method'];
    final path = fields[':path'] ?? '/';
    if (methodName == null) return null;
    HttpMethod method;
    try {
      method = HttpMethod.valueOf(methodName);
    } catch (_) {
      return null;
    }
    final request = HttpRequest(method, path, protocolVersion: 'HTTP/3');
    _applyPseudoAndHeaders(request.headers, fields);
    final body = fields['_body'];
    if (body != null && body.isNotEmpty) request.body = utf8.encode(body);
    final authority = fields[':authority'];
    final scheme = fields[':scheme'] ?? 'https';
    if (authority != null && authority.isNotEmpty) {
      request.hostAndPort = HostAndPort.of('$scheme://$authority');
    }
    return request;
  }

  HttpResponse? _parseHttp3Response(ECaptureEvent event) {
    final binary = ECaptureH3Binary.parseResponse(event.payload);
    if (binary != null) return binary;
    final fields = _http2Fields(event.payload);
    if (fields == null) return null;
    final statusText = fields[':status'];
    final code = int.tryParse(statusText ?? '');
    if (code == null) return null;
    final response = HttpResponse(HttpStatus.valueOf(code), protocolVersion: 'HTTP/3');
    _applyPseudoAndHeaders(response.headers, fields);
    final body = fields['_body'];
    if (body != null && body.isNotEmpty) response.body = utf8.encode(body);
    return response;
  }

  Map<String, String>? _http2Fields(List<int> payload) {
    final text = _payloadText(payload);
    if (!text.contains(':method') && !text.contains(':status') && !text.contains('header field')) {
      return null;
    }
    final fields = <String, String>{};
    final body = StringBuffer();
    var inBody = false;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) {
        inBody = true;
        continue;
      }
      if (!inBody) {
        final header = _matchHeaderLine(line);
        if (header != null) {
          fields[header.$1] = header.$2;
          continue;
        }
        if (line.startsWith('Frame Type') ||
            line.startsWith('Frame StreamID') ||
            line.startsWith('Frame Length') ||
            line.startsWith('[http2')) {
          continue;
        }
        inBody = true;
      }
      if (inBody) {
        if (body.isNotEmpty) body.writeln();
        body.write(raw);
      }
    }
    if (fields.isEmpty) return null;
    if (body.isNotEmpty) fields['_body'] = body.toString();
    return fields;
  }

  (String, String)? _matchHeaderLine(String line) {
    final field = RegExp(r'^header field\s+"([^"]+)"\s*=\s*"(.*)"\s*$', caseSensitive: false).firstMatch(line);
    if (field != null) return (field.group(1)!, field.group(2)!);
    final named = RegExp(r'^([A-Za-z0-9_!#$%&+\-.^`|~:]+)\s*[:=]\s*(.+)$').firstMatch(line);
    if (named != null) return (named.group(1)!.toLowerCase(), named.group(2)!.trim());
    return null;
  }

  void _applyPseudoAndHeaders(HttpHeaders headers, Map<String, String> fields) {
    fields.forEach((name, value) {
      if (name.startsWith('_')) return;
      if (name == ':authority') {
        headers.set(HttpHeaders.HOST, value);
        return;
      }
      if (name.startsWith(':')) return;
      headers.add(name, value);
    });
  }

  void _applyHeaders(HttpHeaders headers, Iterable<String> lines) {
    for (final line in lines) {
      if (line.isEmpty) continue;
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      headers.add(line.substring(0, idx).trim(), line.substring(idx + 1).trim());
    }
  }

  (String, String)? _splitHeadersBody(String text) {
    final crlf = text.indexOf('\r\n\r\n');
    if (crlf >= 0) {
      return (text.substring(0, crlf), text.substring(crlf + 4));
    }
    final lf = text.indexOf('\n\n');
    if (lf >= 0) {
      return (text.substring(0, lf), text.substring(lf + 2));
    }
    if (text.startsWith(RegExp(r'(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|HTTP/)'))) {
      return (text, '');
    }
    return null;
  }

  String _payloadText(List<int> payload) {
    try {
      return utf8.decode(payload);
    } catch (_) {
      return String.fromCharCodes(payload);
    }
  }
}
