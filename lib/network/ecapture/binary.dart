import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/native/ecapture.dart';
import 'package:proxypin/network/util/logger.dart';

class ECaptureBinary {
  static const version = 'v2.9.0';
  static const downloadHost = 'https://github.com/gojue/ecapture/releases/download';

  static Future<File> resolve() async {
    final dir = await getApplicationSupportDirectory();
    final dest = File('${dir.path}${Platform.pathSeparator}ecapture');
    if (await _isUsable(dest)) return dest;

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _download(dest);
        if (await _isUsable(dest)) return dest;
        throw StateError('downloaded eCapture binary is invalid');
      } catch (e) {
        lastError = e;
        logger.w('[eCapture] download attempt ${attempt + 1} failed: $e');
        await Future.delayed(Duration(seconds: 1 + attempt * 2));
      }
    }
    throw StateError('download eCapture failed: $lastError');
  }

  static Future<void> _download(File dest) async {
    final abi = await ECaptureNative.abi();
    final asset = abi.startsWith('x86')
        ? 'ecapture-$version-android-amd64.tar.gz'
        : 'ecapture-$version-android-arm64.tar.gz';
    final url = '$downloadHost/$version/$asset';
    logger.i('[eCapture] downloading $url');
    final tmp = File('${dest.path}.tgz');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      req.maxRedirects = 8;
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw StateError('download eCapture failed: HTTP ${resp.statusCode}');
      }
      final sink = tmp.openWrite();
      try {
        await resp.pipe(sink).timeout(const Duration(minutes: 3));
      } catch (_) {
        await sink.close();
        rethrow;
      }
    } finally {
      client.close(force: true);
    }
    final bytes = await tmp.readAsBytes();
    final tar = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(tar);
    ArchiveFile? elf;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.split('/').last;
      if (name == 'ecapture' || name == 'ecapture.exe') {
        elf = file;
        break;
      }
    }
    elf ??= archive.files.where((f) => f.isFile && !f.name.contains('.')).firstOrNull;
    if (elf == null) {
      throw StateError('eCapture binary missing in $asset');
    }
    final staged = File('${dest.path}.bin');
    await staged.writeAsBytes(elf.content as List<int>, flush: true);
    if (!await _isUsable(staged)) {
      throw StateError('extracted eCapture binary is invalid');
    }
    await dest.writeAsBytes(await staged.readAsBytes(), flush: true);
    if (Platform.isLinux || Platform.isAndroid) {
      await Process.run('chmod', ['755', dest.path]);
    }
  }

  static Future<bool> _isUsable(File file) async {
    if (!await file.exists()) return false;
    if (await file.length() <= 1024 * 1024) return false;
    final raf = await file.open();
    try {
      final header = await raf.read(4);
      return header.length == 4 &&
          header[0] == 0x7f &&
          header[1] == 0x45 &&
          header[2] == 0x4c &&
          header[3] == 0x46;
    } finally {
      await raf.close();
    }
  }
}
