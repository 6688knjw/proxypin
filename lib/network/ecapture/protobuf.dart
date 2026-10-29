import 'dart:convert';
import 'dart:typed_data';

import 'package:proxypin/network/ecapture/event.dart';

class ECaptureProtobuf {
  static ECaptureLogEntry decode(List<int> bytes) {
    final reader = _Reader(bytes);
    var logType = 0;
    ECaptureEvent? event;
    ECaptureHeartbeat? heartbeat;
    String? runLog;

    while (reader.hasMore) {
      final tag = reader.readVarint();
      final field = tag >> 3;
      final wire = tag & 7;
      switch (field) {
        case 1:
          logType = reader.readVarint();
          break;
        case 2:
          event = _decodeEvent(reader.readBytes());
          break;
        case 3:
          heartbeat = _decodeHeartbeat(reader.readBytes());
          break;
        case 4:
          runLog = utf8.decode(reader.readBytes());
          break;
        default:
          reader.skip(wire);
      }
    }

    return ECaptureLogEntry(
      logType: logType,
      event: event,
      heartbeat: heartbeat,
      runLog: runLog,
    );
  }

  static Uint8List encode(ECaptureLogEntry entry) {
    final out = BytesBuilder();
    _writeVarintField(out, 1, entry.logType);
    final event = entry.event;
    if (event != null) {
      _writeBytesField(out, 2, encodeEvent(event));
    }
    final heartbeat = entry.heartbeat;
    if (heartbeat != null) {
      _writeBytesField(out, 3, _encodeHeartbeat(heartbeat));
    }
    if (entry.runLog != null) {
      _writeBytesField(out, 4, utf8.encode(entry.runLog!));
    }
    return out.takeBytes();
  }

  static Uint8List encodeEvent(ECaptureEvent event) {
    final out = BytesBuilder();
    if (event.timestamp != 0) _writeVarintField(out, 1, event.timestamp);
    if (event.uuid.isNotEmpty) _writeBytesField(out, 2, utf8.encode(event.uuid));
    if (event.srcIp.isNotEmpty) _writeBytesField(out, 3, utf8.encode(event.srcIp));
    if (event.srcPort != 0) _writeVarintField(out, 4, event.srcPort);
    if (event.dstIp.isNotEmpty) _writeBytesField(out, 5, utf8.encode(event.dstIp));
    if (event.dstPort != 0) _writeVarintField(out, 6, event.dstPort);
    if (event.pid != 0) _writeVarintField(out, 7, event.pid);
    if (event.pname.isNotEmpty) _writeBytesField(out, 8, utf8.encode(event.pname));
    if (event.type != 0) _writeVarintField(out, 9, event.type);
    if (event.length != 0) _writeVarintField(out, 10, event.length);
    if (event.payload.isNotEmpty) _writeBytesField(out, 11, event.payload);
    if (event.captureFormat != 0) _writeVarintField(out, 12, event.captureFormat);
    if (event.sensitivity != 0) _writeVarintField(out, 13, event.sensitivity);
    if (event.direction.isNotEmpty) _writeBytesField(out, 14, utf8.encode(event.direction));
    if (event.originalLength != 0) _writeVarintField(out, 15, event.originalLength);
    if (event.streamId.isNotEmpty) _writeBytesField(out, 16, utf8.encode(event.streamId));
    if (event.sequence != 0) _writeVarintField(out, 17, event.sequence);
    return out.takeBytes();
  }

  static ECaptureEvent _decodeEvent(List<int> bytes) {
    final reader = _Reader(bytes);
    var timestamp = 0;
    var uuid = '';
    var srcIp = '';
    var srcPort = 0;
    var dstIp = '';
    var dstPort = 0;
    var pid = 0;
    var pname = '';
    var type = 0;
    var length = 0;
    List<int> payload = const [];
    var captureFormat = 0;
    var sensitivity = 0;
    var direction = '';
    var originalLength = 0;
    var streamId = '';
    var sequence = 0;

    while (reader.hasMore) {
      final tag = reader.readVarint();
      final field = tag >> 3;
      final wire = tag & 7;
      switch (field) {
        case 1:
          timestamp = reader.readVarint();
          break;
        case 2:
          uuid = utf8.decode(reader.readBytes());
          break;
        case 3:
          srcIp = utf8.decode(reader.readBytes());
          break;
        case 4:
          srcPort = reader.readVarint();
          break;
        case 5:
          dstIp = utf8.decode(reader.readBytes());
          break;
        case 6:
          dstPort = reader.readVarint();
          break;
        case 7:
          pid = reader.readVarint();
          break;
        case 8:
          pname = utf8.decode(reader.readBytes());
          break;
        case 9:
          type = reader.readVarint();
          break;
        case 10:
          length = reader.readVarint();
          break;
        case 11:
          payload = reader.readBytes();
          break;
        case 12:
          captureFormat = reader.readVarint();
          break;
        case 13:
          sensitivity = reader.readVarint();
          break;
        case 14:
          direction = utf8.decode(reader.readBytes());
          break;
        case 15:
          originalLength = reader.readVarint();
          break;
        case 16:
          streamId = utf8.decode(reader.readBytes());
          break;
        case 17:
          sequence = reader.readVarint();
          break;
        default:
          reader.skip(wire);
      }
    }

    return ECaptureEvent(
      timestamp: timestamp,
      uuid: uuid,
      srcIp: srcIp,
      srcPort: srcPort,
      dstIp: dstIp,
      dstPort: dstPort,
      pid: pid,
      pname: pname,
      type: type,
      length: length,
      payload: payload,
      captureFormat: captureFormat,
      sensitivity: sensitivity,
      direction: direction,
      originalLength: originalLength,
      streamId: streamId,
      sequence: sequence,
    );
  }

  static ECaptureHeartbeat _decodeHeartbeat(List<int> bytes) {
    final reader = _Reader(bytes);
    var timestamp = 0;
    var count = 0;
    var message = '';
    while (reader.hasMore) {
      final tag = reader.readVarint();
      final field = tag >> 3;
      final wire = tag & 7;
      switch (field) {
        case 1:
          timestamp = reader.readVarint();
          break;
        case 2:
          count = reader.readVarint();
          break;
        case 3:
          message = utf8.decode(reader.readBytes());
          break;
        default:
          reader.skip(wire);
      }
    }
    return ECaptureHeartbeat(timestamp: timestamp, count: count, message: message);
  }

  static Uint8List _encodeHeartbeat(ECaptureHeartbeat heartbeat) {
    final out = BytesBuilder();
    if (heartbeat.timestamp != 0) _writeVarintField(out, 1, heartbeat.timestamp);
    if (heartbeat.count != 0) _writeVarintField(out, 2, heartbeat.count);
    if (heartbeat.message.isNotEmpty) {
      _writeBytesField(out, 3, utf8.encode(heartbeat.message));
    }
    return out.takeBytes();
  }

  static void _writeVarintField(BytesBuilder out, int field, int value) {
    _writeVarint(out, (field << 3) | 0);
    _writeVarint(out, value);
  }

  static void _writeBytesField(BytesBuilder out, int field, List<int> value) {
    _writeVarint(out, (field << 3) | 2);
    _writeVarint(out, value.length);
    out.add(value);
  }

  static void _writeVarint(BytesBuilder out, int value) {
    var x = value;
    while (x > 0x7f) {
      out.addByte((x & 0x7f) | 0x80);
      x >>= 7;
    }
    out.addByte(x);
  }
}

class _Reader {
  final List<int> buf;
  int i = 0;

  _Reader(this.buf);

  bool get hasMore => i < buf.length;

  int readVarint() {
    var x = 0;
    var shift = 0;
    while (i < buf.length) {
      final b = buf[i++];
      x |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return x;
      shift += 7;
    }
    throw const FormatException('truncated protobuf varint');
  }

  List<int> readBytes() {
    final n = readVarint();
    if (i + n > buf.length) {
      throw const FormatException('truncated protobuf bytes');
    }
    final out = buf.sublist(i, i + n);
    i += n;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
        break;
      case 1:
        i += 8;
        break;
      case 2:
        final n = readVarint();
        i += n;
        break;
      case 5:
        i += 4;
        break;
      default:
        throw FormatException('unknown protobuf wire type $wire');
    }
  }
}
