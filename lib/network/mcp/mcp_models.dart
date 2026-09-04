import 'dart:convert';

import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';

class McpException implements Exception {
  final int code;
  final String message;
  final Map<String, dynamic>? data;

  const McpException(this.message, {this.code = -32000, this.data});

  factory McpException.methodNotFound(String method) =>
      McpException('Method not found: $method', code: -32601);

  factory McpException.invalidParams(String message) =>
      McpException(message, code: -32602);

  factory McpException.app(String appCode, String message) =>
      McpException(message, data: {'code': appCode, 'message': message});

  Map<String, dynamic> toJsonRpcError() {
    return {
      'code': code,
      'message': message,
      if (data != null) 'data': data,
    };
  }

  @override
  String toString() => message;
}

class BodyPayload {
  final String? text;
  final bool truncated;
  final int originalLength;
  final bool base64;

  const BodyPayload({this.text, this.truncated = false, this.originalLength = 0, this.base64 = false});

  Map<String, dynamic> toJson({String prefix = ''}) {
    return {
      '${prefix}body': text,
      '${prefix}truncated': truncated,
      '${prefix}originalLength': originalLength,
      if (base64) '${prefix}encoding': 'base64',
    };
  }

  static BodyPayload fromBytes(List<int>? body, int limit) {
    if (body == null || body.isEmpty) {
      return const BodyPayload(text: '', truncated: false, originalLength: 0);
    }
    final originalLength = body.length;
    final truncated = originalLength > limit;
    final slice = truncated ? body.sublist(0, limit) : body;
    try {
      return BodyPayload(
        text: utf8.decode(slice),
        truncated: truncated,
        originalLength: originalLength,
      );
    } catch (_) {
      return BodyPayload(
        text: base64Encode(slice),
        truncated: truncated,
        originalLength: originalLength,
        base64: true,
      );
    }
  }
}

class TrafficFilter {
  final String? url;
  final String? method;
  final String? host;
  final int? status;
  final String? keyword;
  final int offset;
  final int limit;
  final String? requestId;

  const TrafficFilter({
    this.url,
    this.method,
    this.host,
    this.status,
    this.keyword,
    this.offset = 0,
    this.limit = 50,
    this.requestId,
  });

  factory TrafficFilter.fromArgs(Map<String, dynamic>? args) {
    args ??= const {};
    return TrafficFilter(
      url: args['url']?.toString(),
      method: args['method']?.toString(),
      host: args['host']?.toString(),
      status: args['status'] is int ? args['status'] as int : int.tryParse('${args['status'] ?? ''}'),
      keyword: args['keyword']?.toString(),
      offset: args['offset'] is int ? args['offset'] as int : int.tryParse('${args['offset'] ?? ''}') ?? 0,
      limit: args['limit'] is int ? args['limit'] as int : int.tryParse('${args['limit'] ?? ''}') ?? 50,
      requestId: args['requestId']?.toString(),
    );
  }

  bool matches(HttpRequest request) {
    if (requestId != null && requestId!.isNotEmpty && request.requestId != requestId) {
      return false;
    }
    final requestUrl = request.requestUrl;
    if (url != null && url!.isNotEmpty && !requestUrl.contains(url!)) {
      return false;
    }
    if (method != null && method!.isNotEmpty && request.method.name.toUpperCase() != method!.toUpperCase()) {
      return false;
    }
    if (host != null && host!.isNotEmpty) {
      final requestHost = request.requestUri?.host ?? request.hostAndPort?.host ?? '';
      if (!requestHost.contains(host!)) {
        return false;
      }
    }
    if (status != null && request.response?.status.code != status) {
      return false;
    }
    if (keyword != null && keyword!.isNotEmpty) {
      final haystack = [
        requestUrl,
        request.method.name,
        request.response?.status.code.toString() ?? '',
        request.bodyAsString,
        request.response?.bodyAsString ?? '',
      ].join(' ').toLowerCase();
      if (!haystack.contains(keyword!.toLowerCase())) {
        return false;
      }
    }
    return true;
  }
}

Map<String, dynamic> trafficSummary(HttpRequest request) {
  final response = request.response;
  return {
    'requestId': request.requestId,
    'method': request.method.name,
    'url': request.requestUrl,
    'status': response?.status.code,
    'contentType': response?.headers.contentType.isNotEmpty == true
        ? response!.headers.contentType
        : (request.headers.contentType.isEmpty ? null : request.headers.contentType),
    'durationMs': response == null ? null : response.responseTime.difference(request.requestTime).inMilliseconds,
    'timestamp': request.requestTime.toUtc().toIso8601String(),
    'bodySize': response?.body?.length ?? request.body?.length,
  };
}

Map<String, List<String>> headerMap(HttpHeaders headers) {
  final map = <String, List<String>>{};
  headers.forEach((name, values) {
    map[name] = List<String>.from(values);
  });
  return map;
}

Map<String, dynamic> trafficDetail(HttpRequest request, int bodyLimit) {
  final requestBody = BodyPayload.fromBytes(request.body, bodyLimit);
  final response = request.response;
  final responseBody = BodyPayload.fromBytes(response?.body, bodyLimit);
  return {
    'summary': trafficSummary(request),
    'requestHeaders': headerMap(request.headers),
    'requestBody': requestBody.text,
    'requestBodyTruncated': requestBody.truncated,
    'requestBodyOriginalLength': requestBody.originalLength,
    if (requestBody.base64) 'requestBodyEncoding': 'base64',
    'responseHeaders': response == null ? null : headerMap(response.headers),
    'responseBody': response == null ? null : responseBody.text,
    'responseBodyTruncated': response == null ? false : responseBody.truncated,
    'responseBodyOriginalLength': response == null ? 0 : responseBody.originalLength,
    if (responseBody.base64) 'responseBodyEncoding': 'base64',
  };
}

class AuditEntry {
  final DateTime time;
  final String tool;
  final String summary;
  final bool ok;

  AuditEntry({required this.time, required this.tool, required this.summary, required this.ok});

  Map<String, dynamic> toJson() {
    return {
      'time': time.toIso8601String(),
      'tool': tool,
      'summary': summary,
      'ok': ok,
    };
  }
}

class McpAuditLog {
  static const int maxEntries = 100;
  final List<AuditEntry> _entries = [];

  List<AuditEntry> get entries => List.unmodifiable(_entries.reversed);

  void add(String tool, String summary, {bool ok = true}) {
    _entries.add(AuditEntry(time: DateTime.now(), tool: tool, summary: summary, ok: ok));
    if (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }
}
