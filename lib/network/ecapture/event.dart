class ECaptureEvent {
  static const int typeUnknown = 0;
  static const int typeHttp1Request = 1;
  static const int typeHttp2Request = 2;
  static const int typeHttp1Response = 3;
  static const int typeHttp2Response = 4;
  static const int typeHttp3Request = 5;
  static const int typeHttp3Response = 6;

  static const int formatUnspecified = 0;
  static const int formatText = 1;
  static const int formatKeylog = 2;
  static const int formatPcapng = 3;

  final int timestamp;
  final String uuid;
  final String srcIp;
  final int srcPort;
  final String dstIp;
  final int dstPort;
  final int pid;
  final String pname;
  final int type;
  final int length;
  final List<int> payload;
  final int captureFormat;
  final int sensitivity;
  final String direction;
  final int originalLength;
  final String streamId;
  final int sequence;

  ECaptureEvent({
    this.timestamp = 0,
    this.uuid = '',
    this.srcIp = '',
    this.srcPort = 0,
    this.dstIp = '',
    this.dstPort = 0,
    this.pid = 0,
    this.pname = '',
    this.type = 0,
    this.length = 0,
    this.payload = const [],
    this.captureFormat = 0,
    this.sensitivity = 0,
    this.direction = '',
    this.originalLength = 0,
    this.streamId = '',
    this.sequence = 0,
  });

  bool get isRequest =>
      type == typeHttp1Request || type == typeHttp2Request || type == typeHttp3Request;

  bool get isResponse =>
      type == typeHttp1Response || type == typeHttp2Response || type == typeHttp3Response;

  bool get isHttp2 => type == typeHttp2Request || type == typeHttp2Response;

  bool get isHttp3 => type == typeHttp3Request || type == typeHttp3Response;

  bool get isTextPayload =>
      captureFormat == formatUnspecified || captureFormat == formatText;

  String get pairKey {
    final stream = streamId.isEmpty ? '0' : streamId;
    return '${_uuidWithoutDirection(uuid)}|$stream|$pid';
  }

  static String _uuidWithoutDirection(String uuid) {
    final parts = uuid.split('_');
    if (parts.length >= 6) {
      parts.removeAt(4);
      return parts.join('_');
    }
    return uuid;
  }
}

class ECaptureHeartbeat {
  final int timestamp;
  final int count;
  final String message;

  ECaptureHeartbeat({this.timestamp = 0, this.count = 0, this.message = ''});
}

class ECaptureLogEntry {
  static const int logHeartbeat = 0;
  static const int logProcess = 1;
  static const int logEvent = 2;

  final int logType;
  final ECaptureEvent? event;
  final ECaptureHeartbeat? heartbeat;
  final String? runLog;

  ECaptureLogEntry({
    required this.logType,
    this.event,
    this.heartbeat,
    this.runLog,
  });
}
