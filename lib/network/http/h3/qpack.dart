import 'dart:convert' show ascii;
import 'dart:typed_data';

import 'package:proxypin/network/http/h2/hpack/hpack.dart';
import 'package:proxypin/network/http/h2/hpack/huffman.dart';
import 'package:proxypin/network/http/h2/hpack/huffman_table.dart';
import 'package:proxypin/network/util/byte_utils.dart';

class QPackDecodingException implements Exception {
  final String message;

  QPackDecodingException(this.message);

  @override
  String toString() => 'QPackDecodingException: $message';
}

class QPackStaticTable {
  static const List<List<String>> entries = [
    [':authority', ''],
    [':path', '/'],
    ['age', '0'],
    ['content-disposition', ''],
    ['content-length', '0'],
    ['cookie', ''],
    ['date', ''],
    ['etag', ''],
    ['if-modified-since', ''],
    ['if-none-match', ''],
    ['last-modified', ''],
    ['link', ''],
    ['location', ''],
    ['referer', ''],
    ['set-cookie', ''],
    [':method', 'CONNECT'],
    [':method', 'DELETE'],
    [':method', 'GET'],
    [':method', 'HEAD'],
    [':method', 'OPTIONS'],
    [':method', 'POST'],
    [':method', 'PUT'],
    [':scheme', 'http'],
    [':scheme', 'https'],
    [':status', '103'],
    [':status', '200'],
    [':status', '304'],
    [':status', '404'],
    [':status', '503'],
    ['accept', '*/*'],
    ['accept', 'application/dns-message'],
    ['accept-encoding', 'gzip, deflate, br'],
    ['accept-ranges', 'bytes'],
    ['access-control-allow-headers', 'cache-control'],
    ['access-control-allow-headers', 'content-type'],
    ['access-control-allow-origin', '*'],
    ['cache-control', 'max-age=0'],
    ['cache-control', 'max-age=2592000'],
    ['cache-control', 'max-age=604800'],
    ['cache-control', 'no-cache'],
    ['cache-control', 'no-store'],
    ['cache-control', 'public, max-age=31536000'],
    ['content-encoding', 'br'],
    ['content-encoding', 'gzip'],
    ['content-type', 'application/dns-message'],
    ['content-type', 'application/javascript'],
    ['content-type', 'application/json'],
    ['content-type', 'application/x-www-form-urlencoded'],
    ['content-type', 'image/gif'],
    ['content-type', 'image/jpeg'],
    ['content-type', 'image/png'],
    ['content-type', 'text/css'],
    ['content-type', 'text/html; charset=utf-8'],
    ['content-type', 'text/plain'],
    ['content-type', 'text/plain;charset=utf-8'],
    ['range', 'bytes=0-'],
    ['strict-transport-security', 'max-age=31536000'],
    ['strict-transport-security', 'max-age=31536000; includesubdomains'],
    ['strict-transport-security', 'max-age=31536000; includesubdomains; preload'],
    ['x-content-type-options', 'nosniff'],
    ['x-xss-protection', '1; mode=block'],
    [':status', '100'],
    [':status', '204'],
    [':status', '206'],
    [':status', '302'],
    [':status', '400'],
    [':status', '403'],
    [':status', '421'],
    [':status', '425'],
    [':status', '500'],
    ['accept-language', ''],
    ['access-control-allow-credentials', 'FALSE'],
    ['access-control-allow-credentials', 'TRUE'],
    ['access-control-allow-headers', '*'],
    ['access-control-allow-methods', 'get'],
    ['access-control-allow-methods', 'get, post, options'],
    ['access-control-allow-methods', 'options'],
    ['access-control-expose-headers', 'content-length'],
    ['access-control-request-headers', 'content-type'],
    ['access-control-request-method', 'get'],
    ['access-control-request-method', 'post'],
    ['alt-svc', 'clear'],
    ['authorization', ''],
    ['content-security-policy', "script-src 'none'; object-src 'none'; base-uri 'none'"],
    ['early-data', '1'],
    ['expect-ct', ''],
    ['forwarded', ''],
    ['if-range', ''],
    ['origin', ''],
    ['purpose', 'prefetch'],
    ['server', ''],
    ['timing-allow-origin', '*'],
    ['upgrade-insecure-requests', '1'],
    ['user-agent', ''],
    ['x-forwarded-for', ''],
    ['x-frame-options', 'deny'],
    ['x-frame-options', 'sameorigin'],
  ];

  static Header lookup(int index) {
    if (index < 0 || index >= entries.length) {
      throw QPackDecodingException('static table index $index');
    }
    final entry = entries[index];
    return Header(ascii.encode(entry[0]), ascii.encode(entry[1]));
  }
}

class QPackDecoder {
  List<Header> decodeFieldSection(List<int> data) {
    if (data.isEmpty) return const [];
    final reader = _QPackReader(data);
    try {
      reader.readInteger(8);
      reader.readInteger(7);
      final headers = <Header>[];
      while (reader.hasMore) {
        final byte = reader.peek();
        if ((byte & 0x80) != 0) {
          final fromStatic = (byte & 0x40) != 0;
          final index = reader.readInteger(6);
          if (!fromStatic) break;
          headers.add(QPackStaticTable.lookup(index));
        } else if ((byte & 0x40) != 0) {
          final fromStatic = (byte & 0x10) != 0;
          final index = reader.readInteger(4);
          final value = reader.readStringLiteral(8);
          if (!fromStatic) break;
          headers.add(Header(QPackStaticTable.lookup(index).name, value));
        } else if ((byte & 0xe0) == 0x20) {
          final name = reader.readPrefixedString(3);
          final value = reader.readStringLiteral(8);
          headers.add(Header(name, value));
        } else {
          break;
        }
      }
      return headers;
    } on RangeError catch (e) {
      throw QPackDecodingException('$e');
    } on HuffmanDecodingException catch (e) {
      throw QPackDecodingException('$e');
    }
  }
}

class _QPackReader {
  final List<int> data;
  int offset = 0;

  _QPackReader(this.data);

  bool get hasMore => offset < data.length;

  int peek() {
    if (offset >= data.length) {
      throw RangeError('qpack truncated');
    }
    return data[offset];
  }

  int readInteger(int prefixBits) {
    var byte = data[offset++] & ((1 << prefixBits) - 1);
    if (byte != ((1 << prefixBits) - 1)) {
      return byte;
    }
    var integer = 0;
    var shift = 0;
    while (true) {
      final done = (data[offset] & 0x80) != 0x80;
      integer += (data[offset++] & 0x7f) << shift;
      shift += 7;
      if (done) break;
    }
    return integer + ((1 << prefixBits) - 1);
  }

  List<int> readStringLiteral(int prefixBits) {
    return readPrefixedString(prefixBits - 1);
  }

  List<int> readPrefixedString(int lengthPrefixBits) {
    final isHuffman = (data[offset] & (1 << lengthPrefixBits)) != 0;
    final length = readInteger(lengthPrefixBits);
    final sublist = viewOrSublist(data, offset, length);
    offset += length;
    if (isHuffman) {
      return http2HuffmanCodec.decode(sublist);
    }
    return sublist;
  }
}

class QPackEncoder {
  List<int> encodeFieldSection(List<Header> headers) {
    final out = BytesBuilder();
    out.addByte(0);
    out.addByte(0);
    for (final header in headers) {
      final name = header.nameString;
      final value = header.valueString;
      var staticIndex = -1;
      var nameIndex = -1;
      for (var i = 0; i < QPackStaticTable.entries.length; i++) {
        final entry = QPackStaticTable.entries[i];
        if (entry[0] != name) continue;
        nameIndex = nameIndex < 0 ? i : nameIndex;
        if (entry[1] == value) {
          staticIndex = i;
          break;
        }
      }
      if (staticIndex >= 0) {
        _writePrefixed(out, 0xc0, 6, staticIndex);
      } else if (nameIndex >= 0) {
        _writePrefixed(out, 0x50, 4, nameIndex);
        _writeString(out, header.value);
      } else {
        _writePrefixed(out, 0x20, 3, header.name.length);
        out.add(header.name);
        _writeString(out, header.value);
      }
    }
    return out.takeBytes();
  }

  void _writePrefixed(BytesBuilder out, int mask, int prefixBits, int value) {
    final max = (1 << prefixBits) - 1;
    if (value < max) {
      out.addByte(mask | value);
      return;
    }
    out.addByte(mask | max);
    var rest = value - max;
    while (rest >= 128) {
      out.addByte((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    out.addByte(rest);
  }

  void _writeString(BytesBuilder out, List<int> bytes) {
    _writePrefixed(out, 0, 7, bytes.length);
    out.add(bytes);
  }
}
