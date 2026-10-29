import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:proxypin/network/util/process_info.dart';

class ECaptureNative {
  static const MethodChannel _channel = MethodChannel('com.proxy/ecapture');

  static Future<bool> isRooted() async {
    try {
      return await _channel.invokeMethod<bool>('isRooted') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<String> abi() async {
    try {
      return await _channel.invokeMethod<String>('abi') ?? 'arm64-v8a';
    } on MissingPluginException {
      return 'arm64-v8a';
    }
  }

  static Future<Map<String, dynamic>> start({
    required String binaryPath,
    String wsUrl = 'ws://127.0.0.1:28257',
  }) async {
    try {
      final raw = await _channel.invokeMethod('start', {
        'binaryPath': binaryPath,
        'wsUrl': wsUrl,
      });
      if (raw is Map) {
        return raw.map((key, value) => MapEntry(key.toString(), value));
      }
      return {'ok': false, 'error': 'empty result'};
    } on MissingPluginException {
      return {'ok': false, 'error': 'plugin missing'};
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.message ?? e.code};
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      return;
    }
  }

  static Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<ProcessInfo?> getProcessByPid(int pid) async {
    if (pid <= 0) return null;
    try {
      final raw = await _channel.invokeMethod('getProcessByPid', {'pid': pid});
      if (raw is! Map) return null;
      final iconRaw = raw['icon'];
      return ProcessInfo(
        raw['packageName'] as String? ?? '',
        raw['name']?.toString() ?? 'pid-$pid',
        raw['packageName'] as String? ?? '',
        os: 'android',
        icon: iconRaw is Uint8List
            ? iconRaw
            : iconRaw is List
                ? Uint8List.fromList(iconRaw.cast<int>())
                : null,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
