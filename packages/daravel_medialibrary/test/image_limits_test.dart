import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart' show ConfigException, Env, EnvException;
import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A small file can declare a huge image: a 1 MiB PNG of 16 000 x 16 000
/// RGBA pixels took 2.2 GiB to convert. The size is now read from the
/// header and checked before anything is decoded. Each file is converted
/// in a compiled child process bounded in time, which reports its peak
/// RSS.
void main() {
  followUpTests();
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

  containerTests((bytes) => convert(bytes));
  tiffAndBudgetTests();

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

void followUpTests() {
  test('MEDIA_MAX_IMAGE_PIXELS or _FRAMES below 1 stops the boot', () {
    for (final key in ['MEDIA_MAX_IMAGE_PIXELS', 'MEDIA_MAX_IMAGE_FRAMES']) {
      for (final value in ['0', '-1']) {
        expect(
          () => MediaLibraryConfig.fromEnv(Env.fromMap({key: value})),
          throwsA(isA<ConfigException>()),
          reason: '$key=$value',
        );
      }
      expect(
        () => MediaLibraryConfig.fromEnv(Env.fromMap({key: 'lots'})),
        throwsA(isA<EnvException>()),
        reason: '$key=lots',
      );
    }
    final config = MediaLibraryConfig.fromEnv(
      Env.fromMap({
        'MEDIA_MAX_IMAGE_PIXELS': '1000',
        'MEDIA_MAX_IMAGE_FRAMES': '2',
      }),
    );
    expect([config.maxImagePixels, config.maxImageFrames], [1000, 2]);
  });

  test('formats other than JPEG, PNG, GIF, WebP, TIFF and BMP are not '
      'decoded, whatever the name', () {
    final pixel = img.Image(width: 1, height: 1);
    for (final bytes in [img.encodeTga(pixel), img.encodeIco(pixel)]) {
      expect(
        () => convertImageSync(bytes, {
          'width': [1],
        }),
        throwsA(
          isA<ImageConversionException>().having(
            (e) => e.message,
            'message',
            contains('not a JPEG, PNG, GIF, WebP or BMP'),
          ),
        ),
      );
    }
  });
}

/// An APNG whose canvas (`IHDR`) is 1 x 1 and whose second frame (`fcTL`)
/// declares [width] x [height], with its rows of zeros in `fdAT`.
Uint8List _apngWithHugeFrame(int width, int height) {
  ByteData u32s(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i]);
    }
    return data;
  }

  List<int> fctl(int sequence, int w, int h) => [
    ...u32s([sequence, w, h, 0, 0]).buffer.asUint8List(),
    0, 1, 0, 1, // delay 1/1
    0, 0, // dispose, blend
  ];

  final out = BytesBuilder(copy: false)
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, 1)
    ..setUint32(4, 1)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  out
    ..add(_chunk('IHDR', ihdr.buffer.asUint8List()))
    ..add(_chunk('acTL', u32s([2, 0]).buffer.asUint8List()))
    ..add(_chunk('fcTL', fctl(0, 1, 1)))
    ..add(_chunk('IDAT', ZLibEncoder().convert([0, 0, 0, 0, 0])));
  final compressed = BytesBuilder(copy: false);
  final sink = ZLibEncoder().startChunkedConversion(
    ByteConversionSink.withCallback(compressed.add),
  );
  final row = Uint8List(1 + width * 4);
  for (var y = 0; y < height; y++) {
    sink.add(row);
  }
  sink.close();
  out
    ..add(_chunk('fcTL', fctl(1, width, height)))
    ..add(
      _chunk('fdAT', [
        ...u32s([2]).buffer.asUint8List(),
        ...compressed.takeBytes(),
      ]),
    )
    ..add(_chunk('IEND', const []));
  return out.takeBytes();
}

/// An animated WebP whose canvas (`VP8X`) is [canvas] x [canvas] ([frame] by
/// default) and whose single frame (`ANMF`) is [frame] x [frame], holding a
/// lossless (`VP8L`) bitstream of [bitstream] x [bitstream].
Uint8List _animatedWebp({
  required int frame,
  required int bitstream,
  int? canvas,
}) {
  final side = canvas ?? frame;
  List<int> le24(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF];
  List<int> chunk(String type, List<int> data) => [
    ...ascii.encode(type),
    ...(ByteData(
      4,
    )..setUint32(0, data.length, Endian.little)).buffer.asUint8List(),
    ...data,
    if (data.length.isOdd) 0,
  ];
  final bits = (bitstream - 1) | ((bitstream - 1) << 14);
  final vp8l = chunk('VP8L', [
    0x2F,
    bits & 0xFF,
    (bits >> 8) & 0xFF,
    (bits >> 16) & 0xFF,
    (bits >> 24) & 0xFF,
    // A minimal valid lossless image: one colour throughout.
    0x88, 0x88, 0x08,
    ...List.filled(16, 0),
  ]);
  final body = [
    ...ascii.encode('WEBP'),
    // Animation flag; canvas [side] x [side].
    ...chunk('VP8X', [0x02, 0, 0, 0, ...le24(side - 1), ...le24(side - 1)]),
    ...chunk('ANIM', [0, 0, 0, 0, 0, 0]),
    // Offset 0,0; frame [frame] x [frame]; duration 1; no flags.
    ...chunk('ANMF', [
      ...le24(0),
      ...le24(0),
      ...le24(frame - 1),
      ...le24(frame - 1),
      ...le24(1),
      0,
      ...vp8l,
    ]),
  ];
  return Uint8List.fromList([
    ...ascii.encode('RIFF'),
    ...(ByteData(
      4,
    )..setUint32(0, body.length, Endian.little)).buffer.asUint8List(),
    ...body,
  ]);
}

void containerTests(Future<(String, int)> Function(List<int>) convert) {
  const mib = 1024 * 1024;
  test('an APNG frame larger than its canvas is refused', () async {
    final (line, rss) = await convert(_apngWithHugeFrame(16000, 16000));
    expect(line, 'error ImageConversionException');
    expect(rss, lessThan(300 * mib));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('an animated WebP frame whose bitstream size differs from its frame '
      'header is refused', () async {
    final (line, _) = await convert(_animatedWebp(frame: 2, bitstream: 1));
    expect(line, 'error ImageConversionException');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'an animated WebP whose frames match their bitstreams converts',
    () async {
      final (line, _) = await convert(_animatedWebp(frame: 2, bitstream: 2));
      expect(line, startsWith('ok '));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // RSEQ 63: a frame must lie inside its canvas.
  test('an animated WebP frame outside its canvas is refused', () {
    expect(
      () => convertImageSync(_animatedWebp(frame: 2, bitstream: 2, canvas: 1), {
        'width': [1],
      }),
      throwsA(isA<ImageConversionException>()),
    );
  });

  test('an APNG frame outside its image is refused; frames inside convert', () {
    expect(
      () => convertImageSync(_apngWithHugeFrame(2, 2), {
        'width': [1],
      }),
      throwsA(isA<ImageConversionException>()),
    );
    final animation = img.Image(width: 4, height: 4, numChannels: 4)
      ..addFrame(img.Image(width: 4, height: 4, numChannels: 4));
    expect(
      convertImageSync(img.encodePng(animation), {
        'width': [2],
      }),
      isNotEmpty,
    );
  });

  test('a JPEG of 4 color components is refused before it is decoded', () {
    expect(
      () => convertImageSync(_jpegComponents(4), {
        'width': [1],
      }),
      throwsA(
        isA<ImageConversionException>().having(
          (e) => e.message,
          'message',
          contains('4 color components'),
        ),
      ),
    );
  });
}

/// An 8 x 8 progressive (`SOF2`) JPEG of [components] components with no
/// real scan data.
Uint8List _jpegComponents(int components) {
  final sof = <int>[
    8, 0, 8, 0, 8, components, //
    for (var i = 1; i <= components; i++) ...[i, 0x11, 0],
  ];
  final dqt = List<int>.filled(65, 1)..[0] = 0;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xDB, 0, dqt.length + 2, ...dqt,
    0xFF, 0xC2, 0, sof.length + 2, ...sof,
    0xFF, 0xDA, 0, 8, 1, 1, 0x00, 0, 0, 0,
    0x00, 0xFF, 0xD9,
  ]);
}

void tiffAndBudgetTests() {
  test('TIFF is not converted in this version', () {
    expect(canConvert(mimeType: 'image/tiff'), isFalse);
    expect(canConvert(extension: 'tif'), isFalse);
    expect(canConvert(extension: 'tiff'), isFalse);
    expect(canConvert(mimeType: 'image/png'), isTrue);
    expect(
      () => convertImageSync(img.encodeTiff(img.Image(width: 4, height: 4)), {
        'width': [2],
      }),
      throwsA(
        isA<ImageConversionException>().having(
          (e) => e.message,
          'message',
          contains('TIFF is not converted'),
        ),
      ),
    );
  });

  test('a 16-bit PNG counts two bytes per sample against the budget', () {
    Uint8List png(img.Format format) => img.encodePng(
      img.Image(width: 8, height: 8, format: format, numChannels: 4),
    );
    // 64 pixels: under a limit of 100, but not under half of it.
    expect(
      convertImageSync(png(img.Format.uint8), {
        'width': [4],
      }, maxPixels: 100),
      isNotEmpty,
    );
    expect(
      () => convertImageSync(png(img.Format.uint16), {
        'width': [4],
      }, maxPixels: 100),
      throwsA(isA<ImageTooLargeException>()),
    );
  });

  test('limits below 1 and images of no width are refused', () {
    final png = img.encodePng(img.Image(width: 2, height: 2));
    for (final (pixels, frames) in [(0, 1), (1, 0), (-5, 10)]) {
      expect(
        () => convertImageSync(
          png,
          {
            'width': [1],
          },
          maxPixels: pixels,
          maxFrames: frames,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => convertImageSync(_hugeRleBmp(-5, 5), {
        'width': [1],
      }),
      throwsA(isA<ImageConversionException>()),
    );
  });
}
