import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A small file can declare a huge image: a 1 MiB PNG of 16 000 x 16 000
/// RGBA pixels took 2.2 GiB to convert. The size is now read from the
/// header and checked before anything is decoded. Each file is converted
/// in a compiled child process bounded in time, which reports its peak
/// RSS.
void main() {
  late Directory dir;
  late String child;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('daravel_media_limits');
    child = '${dir.path}/convert_child${Platform.isWindows ? '.exe' : ''}';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/support/convert_child.dart',
      '-o',
      child,
    ]);
    if (compiled.exitCode != 0) {
      throw StateError('${compiled.stdout}${compiled.stderr}');
    }
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  /// Converts [bytes] in the child: its first line and peak RSS, or `hung`
  /// after [limit].
  Future<(String, int)> convert(
    List<int> bytes, {
    Duration limit = const Duration(seconds: 30),
  }) async {
    final file = File('${dir.path}/image-${bytes.hashCode}')
      ..writeAsBytesSync(bytes);
    final process = await Process.start(child, [file.path]);
    final output = process.stdout.transform(utf8.decoder).join();
    unawaited(process.stderr.drain<void>());
    try {
      await process.exitCode.timeout(limit);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return ('hung', 0);
    }
    final lines = const LineSplitter().convert(await output);
    return (lines.first, int.parse(lines.last.split(' ').last));
  }

  const mib = 1024 * 1024;

  test('a PNG declaring 16 000 x 16 000 RGBA pixels is refused', () async {
    final png = _hugePng(16000, 16000);
    expect(png.length, lessThan(2 * mib));
    final (line, rss) = await convert(png);
    expect(line, 'error ImageTooLargeException');
    expect(rss, lessThan(300 * mib));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a GIF declaring 16 000 x 16 000 pixels is refused', () async {
    final (line, rss) = await convert(_hugeGif(16000, 16000));
    expect(line, 'error ImageTooLargeException');
    expect(rss, lessThan(300 * mib));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a GIF of 1 500 frames is refused', () async {
    final animation = img.Image(width: 64, height: 64, numChannels: 3);
    for (var i = 1; i < 1500; i++) {
      animation.addFrame(img.Image(width: 64, height: 64, numChannels: 3));
    }
    final (line, rss) = await convert(img.encodeGif(animation));
    expect(line, 'error ImageTooLargeException');
    expect(rss, lessThan(300 * mib));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'a run-length BMP declaring 16 000 x 16 000 pixels is refused',
    () async {
      final (line, rss) = await convert(_hugeRleBmp(16000, 16000));
      expect(line, 'error ImageTooLargeException');
      expect(rss, lessThan(300 * mib));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a WebP declaring 16 384 x 16 384 pixels is refused', () async {
    final (line, rss) = await convert(_hugeLosslessWebp(16384, 16384));
    expect(line, 'error ImageTooLargeException');
    expect(rss, lessThan(300 * mib));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a 24 MP photo still converts', () async {
    final photo = img.encodeJpg(img.Image(width: 6000, height: 4000));
    final (line, _) = await convert(photo, limit: const Duration(minutes: 1));
    expect(line, startsWith('ok '));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// A PNG of [width] x [height] RGBA pixels, all zero: rows compress to
/// almost nothing, so the file is small and the image is not.
Uint8List _hugePng(int width, int height) {
  final out = BytesBuilder(copy: false)
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // RGBA
  out.add(_chunk('IHDR', ihdr.buffer.asUint8List()));
  final compressed = BytesBuilder(copy: false);
  final sink = ZLibEncoder().startChunkedConversion(
    ByteConversionSink.withCallback(compressed.add),
  );
  final row = Uint8List(1 + width * 4); // filter 0, then zeros
  for (var y = 0; y < height; y++) {
    sink.add(row);
  }
  sink.close();
  out
    ..add(_chunk('IDAT', compressed.takeBytes()))
    ..add(_chunk('IEND', const []));
  return out.takeBytes();
}

List<int> _chunk(String type, List<int> data) {
  final header = ByteData(4)..setUint32(0, data.length);
  final typed = [...ascii.encode(type), ...data];
  final crc = ByteData(4)..setUint32(0, _crc32(typed));
  return [
    ...header.buffer.asUint8List(),
    ...typed,
    ...crc.buffer.asUint8List(),
  ];
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A one-pixel GIF whose screen and frame declare [width] x [height].
Uint8List _hugeGif(int width, int height) {
  final gif = img.encodeGif(img.Image(width: 1, height: 1, numChannels: 3));
  final data = ByteData.sublistView(gif);
  // Logical screen descriptor at 6.
  data
    ..setUint16(6, width, Endian.little)
    ..setUint16(8, height, Endian.little);
  // The first image descriptor (0x2C): its width and height at +5 and +7.
  final at = gif.indexOf(0x2C, 13);
  data
    ..setUint16(at + 5, width, Endian.little)
    ..setUint16(at + 7, height, Endian.little);
  return gif;
}

/// An 8-bit run-length BMP of [width] x [height] whose data ends at once.
Uint8List _hugeRleBmp(int width, int height) {
  const palette = 256 * 4;
  const offset = 14 + 40 + palette;
  final bytes = ByteData(offset + 2)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, offset + 2, Endian.little)
    ..setUint32(10, offset, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little) // planes
    ..setUint16(28, 8, Endian.little) // bits per pixel
    ..setUint32(30, 1, Endian.little) // BI_RLE8
    ..setUint32(34, 2, Endian.little)
    ..setUint32(46, 256, Endian.little)
    // End of bitmap.
    ..setUint8(offset, 0)
    ..setUint8(offset + 1, 1);
  return bytes.buffer.asUint8List();
}

/// A lossless WebP header declaring [width] x [height] (at most 16 384).
Uint8List _hugeLosslessWebp(int width, int height) {
  final bits = (width - 1) | ((height - 1) << 14);
  final vp8l = [
    0x2F,
    bits & 0xFF,
    (bits >> 8) & 0xFF,
    (bits >> 16) & 0xFF,
    (bits >> 24) & 0xFF,
    ...List.filled(16, 0),
  ];
  final chunk = [
    ...ascii.encode('VP8L'),
    ...(ByteData(
      4,
    )..setUint32(0, vp8l.length, Endian.little)).buffer.asUint8List(),
    ...vp8l,
  ];
  return Uint8List.fromList([
    ...ascii.encode('RIFF'),
    ...(ByteData(
      4,
    )..setUint32(0, 4 + chunk.length, Endian.little)).buffer.asUint8List(),
    ...ascii.encode('WEBP'),
    ...chunk,
  ]);
}
