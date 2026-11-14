import 'dart:typed_data';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// What a conversion makes is bounded too, not only what it reads: a thin
/// file resized to a width grows by its aspect ratio (1 x 15 000 to a width
/// of 100 is 100 x 1 500 000), and making an image costs time with its
/// pixels. A manipulation makes at most the larger of the image's own
/// pixels and a quarter of the pixel limit, with sides of at most 65 535;
/// an image read has sides of at most 65 535; a JPEG has at most as many
/// scans as its size allows.
void main() {
  /// Converts [bytes] with [manipulations], failing the test when it takes
  /// longer than [within]: each refusal here comes before any large image
  /// is made.
  Object? convert(
    Uint8List bytes,
    Map<String, List<Object?>> manipulations, {
    int? maxPixels,
    Duration within = const Duration(seconds: 2),
  }) {
    final watch = Stopwatch()..start();
    Object? outcome;
    try {
      outcome = maxPixels == null
          ? convertImageSync(bytes, manipulations)
          : convertImageSync(bytes, manipulations, maxPixels: maxPixels);
    } on ImageConversionException catch (error) {
      outcome = error;
    }
    expect(watch.elapsed, lessThan(within), reason: '$manipulations');
    return outcome;
  }

  Uint8List png(int width, int height) =>
      img.encodePng(img.Image(width: width, height: height));

  final refused = isA<ImageTooLargeException>();
  final converted = isA<Uint8List>();

  group('a manipulation does not grow a thin image without bound', () {
    test('width() and height() on an image of extreme ratio', () {
      expect(
        convert(png(1, 15000), {
          'width': [100],
        }),
        refused,
      );
      expect(
        convert(png(15000, 1), {
          'height': [100],
        }),
        refused,
      );
      final gif = img.encodeGif(
        img.Image(width: 1, height: 65535, numChannels: 1, withPalette: true),
      );
      expect(
        convert(gif, {
          'width': [100],
        }),
        refused,
      );
    });

    test('each Fit on a thin image: only crop would grow it', () {
      final thin = png(1, 300);
      expect(
        convert(thin, {
          'fit': ['crop', 800, 800],
        }),
        refused,
      );
      for (final fit in ['contain', 'max', 'fill', 'stretch', 'fillMax']) {
        expect(
          convert(thin, {
            'fit': [fit, 800, 800],
          }),
          converted,
          reason: fit,
        );
      }
    });

    test('growing stops at a quarter of the pixel limit, frames counted', () {
      // maxPixels 400 000: an image may grow to 100 000 pixels.
      final square = png(100, 100);
      expect(
        convert(square, {
          'width': [316],
        }, maxPixels: 400000),
        converted,
      );
      expect(
        convert(square, {
          'width': [317],
        }, maxPixels: 400000),
        refused,
      );
      // Ten frames of 10 x 10: each frame is resized.
      final animation = img.Image(
        width: 10,
        height: 10,
        numChannels: 1,
        withPalette: true,
      );
      for (var i = 1; i < 10; i++) {
        animation.addFrame(
          img.Image(width: 10, height: 10, numChannels: 1, withPalette: true),
        );
      }
      final gif = img.encodeGif(animation);
      expect(
        convert(gif, {
          'width': [100],
        }, maxPixels: 400000),
        converted,
      );
      expect(
        convert(gif, {
          'width': [101],
        }, maxPixels: 400000),
        refused,
      );
      expect(
        convert(png(10, 10), {
          'width': [101],
        }, maxPixels: 400000),
        converted,
        reason: 'one frame of the same size',
      );
    });

    test('shrinking is allowed whatever the size', () {
      expect(
        convert(png(2000, 1000), {
          'width': [100],
        }, maxPixels: 400000 * 8),
        converted,
      );
    });

    test('1080p to 4K converts at the default limit', () {
      expect(
        convert(png(1920, 1080), {
          'width': [3840],
        }, within: const Duration(seconds: 30)),
        converted,
      );
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  test('a side longer than 65 535 is refused before decoding; 65 535 '
      'converts', () {
    expect(convert(png(1, 70000), {}), refused);
    expect(convert(png(70000, 1), {}), refused);
    expect(convert(png(1, 65535), {}), converted);
  });

  group('JPEG scans', () {
    test('an ordinary progressive JPEG of 10 scans converts', () {
      final jpeg = _progressiveJpeg(64, 48, 10);
      expect(img.JpegDecoder().decode(jpeg), isNotNull);
      expect(
        convert(jpeg, {
          'width': [32],
        }),
        converted,
      );
    });

    test('more scans than its size allows: refused before decoding', () {
      // 8 000 x 5 000 allows 16 scans at the default limit.
      expect(convert(_scansOnly(8000, 5000, 16), {}), isNot(refused));
      expect(convert(_scansOnly(8000, 5000, 17), {}), refused);
      // A small image allows many more.
      expect(convert(_scansOnly(64, 48, 17), {}), isNot(refused));
    });

    test('the scans are counted against the largest frame header in the '
        'file, not only the first', () {
      // The first frame is 64 x 48; a second header of 8 000 x 5 000 sits
      // in a comment. 17 scans are too many for the larger one.
      expect(convert(_scansOnly(64, 48, 17), {}), isNot(refused));
      expect(
        convert(_scansOnly(64, 48, 17, comment: _frameHeader(8000, 5000)), {}),
        refused,
      );
      // Bytes that only look like a frame header (no components) count
      // too: they only tighten the budget, and 16 scans or fewer always
      // pass, since no candidate is larger than the pixel limit.
      final lookAlike = _frameHeader(8000, 5000)..[9] = 0;
      expect(convert(_scansOnly(64, 48, 17, comment: lookAlike), {}), refused);
      expect(
        convert(_scansOnly(64, 48, 16, comment: lookAlike), {}),
        isNot(refused),
      );
      // A candidate past the pixel limit is not one.
      expect(
        convert(_scansOnly(64, 48, 17, comment: _frameHeader(9000, 5000)), {}),
        isNot(refused),
      );
    });
  });
}

/// A progressive frame header of [width] x [height], one component.
List<int> _frameHeader(int width, int height) => [
  0xFF, 0xC2, ..._be16(11), 8, ..._be16(height), ..._be16(width), 1, //
  1, 0x11, 0,
];

List<int> _be16(int value) => [(value >> 8) & 0xFF, value & 0xFF];

/// A grey progressive JPEG of [width] x [height] (one component) in
/// [scans] scans: DC, then AC with an end of block in every block, then
/// AC refinements.
Uint8List _progressiveJpeg(int width, int height, int scans) {
  final blocks = ((width + 7) ~/ 8) * ((height + 7) ~/ 8);
  // One bit a block, padded with ones.
  final data = Uint8List((blocks + 7) ~/ 8);
  if (blocks % 8 != 0) {
    data[data.length - 1] = (1 << (8 - blocks % 8)) - 1;
  }
  final out = BytesBuilder()
    ..add([0xFF, 0xD8])
    ..add([0xFF, 0xDB, ..._be16(67), 0, ...List.filled(64, 1)])
    ..add([
      0xFF, 0xC2, ..._be16(11), 8, ..._be16(height), ..._be16(width), 1, //
      1, 0x11, 0,
    ])
    // DC: one code of one bit, a difference of 0. AC: one code of one bit,
    // end of block.
    ..add([0xFF, 0xC4, ..._be16(19), 0x00, 1, ...List.filled(15, 0), 0x00])
    ..add([0xFF, 0xC4, ..._be16(19), 0x10, 1, ...List.filled(15, 0), 0x00])
    ..add([0xFF, 0xDA, ..._be16(8), 1, 1, 0x00, 0, 0, 0x00])
    ..add(data);
  for (var scan = 1; scan < scans; scan++) {
    out
      ..add([0xFF, 0xDA, ..._be16(8), 1, 1, 0x00, 1, 63, scan == 1 ? 1 : 0x10])
      ..add(data);
  }
  out.add([0xFF, 0xD9]);
  return out.takeBytes();
}

/// A JPEG header of [width] x [height] followed by [scans] empty scans, and
/// [comment] in a comment segment after the frame: the count is checked
/// before anything is decoded.
Uint8List _scansOnly(
  int width,
  int height,
  int scans, {
  List<int> comment = const [],
}) => Uint8List.fromList([
  0xFF, 0xD8, //
  0xFF, 0xDB, ..._be16(67), 0, ...List.filled(64, 1),
  ..._frameHeader(width, height),
  if (comment.isNotEmpty) ...[0xFF, 0xFE, ..._be16(2 + comment.length)],
  ...comment,
  for (var i = 0; i < scans; i++) ...[
    0xFF, 0xDA, ..._be16(8), 1, 1, 0x00, 0, 0, 0x00, //
  ],
  0xFF, 0xD9,
]);
