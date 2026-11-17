import 'dart:math';
import 'dart:typed_data';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
// The walk the conversion follows before decoding; not exported.
import 'package:daravel_medialibrary/src/jpeg_walk.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// What a conversion makes is bounded too, not only what it reads: a thin
/// file resized to a width grows by its aspect ratio (1 x 15 000 to a width
/// of 100 is 100 x 1 500 000), and making an image costs time with its
/// pixels. A manipulation makes at most a quarter of the pixel limit,
/// with sides of at most 65 535; blur has a separate work budget;
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

    test('Fit.fill and Fit.fillMax keep every frame of an animation', () {
      final animation = img.Image(width: 40, height: 20)..frameDuration = 10;
      for (var i = 1; i < 3; i++) {
        animation.addFrame(
          img.Image(width: 40, height: 20)..frameDuration = 10 * (i + 1),
        );
      }
      final gif = img.encodeGif(animation);
      for (final fit in ['fill', 'fillMax']) {
        final out = convert(gif, {
          'fit': [fit, 30, 30],
          'format': ['gif'],
        });
        expect(out, converted, reason: fit);
        final decoded = img.decodeGif(out! as Uint8List)!;
        expect(decoded.numFrames, 3, reason: fit);
        expect([decoded.width, decoded.height], [30, 30], reason: fit);
        expect(
          [for (final frame in decoded.frames) frame.frameDuration],
          [10, 20, 30],
          reason: fit,
        );
      }
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

    test('a shrink is bounded by its output, not by its larger input', () {
      final source = png(2000, 1000);
      // maxPixels 4 000 000: each output may hold at most 1 000 000.
      expect(
        convert(source, {
          'width': [1414],
        }, maxPixels: 4000000),
        converted,
      );
      expect(
        convert(source, {
          'width': [1500],
        }, maxPixels: 4000000),
        refused,
      );
    });

    test('a crop is bounded by its output, not by its larger input', () {
      final source = png(2000, 1000);
      // maxPixels 4 000 000: each output may hold at most 1 000 000.
      expect(
        convert(source, {
          'crop': [1000, 1000, 'center'],
        }, maxPixels: 4000000),
        converted,
      );
      expect(
        convert(source, {
          'crop': [1500, 1000, 'center'],
        }, maxPixels: 4000000),
        refused,
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

  group('GIF output is bounded', () {
    Uint8List animation(int frames) {
      final first = img.Image(width: 20, height: 20);
      for (var i = 1; i < frames; i++) {
        first.addFrame(img.Image(width: 20, height: 20));
      }
      return img.encodeGif(first);
    }

    test('an animation at the GIF limit is written, one frame more is '
        'refused before encoding', () {
      // maxPixels 400 000: the GIF limit is 40 000, 100 frames of 20 x 20.
      expect(
        convert(animation(100), {
          'format': ['gif'],
        }, maxPixels: 400000),
        converted,
      );
      expect(
        convert(animation(101), {
          'format': ['gif'],
        }, maxPixels: 400000),
        refused,
      );
    });

    test('maxGifPixels raises it', () {
      expect(
        convertImageSync(
          animation(101),
          {
            'format': ['gif'],
          },
          maxPixels: 400000,
          maxGifPixels: 50000,
        ),
        converted,
      );
    });

    test('a small PNG enlarged to 10 million pixels is refused as a GIF '
        'before encoding, and converts as a JPEG', () {
      final small = png(100, 100);
      final enlarge = <String, List<Object?>>{
        'width': [3162],
      };
      // The resize itself takes a few seconds; encoding the GIF would add
      // 6 to 11.
      expect(
        convert(small, {
          ...enlarge,
          'format': ['gif'],
        }, within: const Duration(seconds: 5)),
        refused,
      );
      expect(
        convert(small, enlarge, within: const Duration(seconds: 10)),
        converted,
      );
    });
  });

  group('blur work is bounded', () {
    Uint8List png16(int width, int height) => img.encodePng(
      img.Image(width: width, height: height, format: img.Format.uint16),
    );

    Uint8List pngWith(int width, int height, int channels) => img.encodePng(
      img.Image(width: width, height: height, numChannels: channels),
    );

    test('blur work counts the channels (measured on three)', () {
      // 2 000 x 2 000 at radius 20: 80 million for three channels.
      final blur40 = <String, List<Object?>>{
        'blur': [40],
      };
      expect(convert(pngWith(2000, 2000, 4), blur40), refused);
      expect(
        convert(
          pngWith(2000, 2000, 3),
          blur40,
          within: const Duration(seconds: 10),
        ),
        converted,
      );
      // 3 000 x 3 000: 180 million for three, 60 million for one.
      expect(convert(pngWith(3000, 3000, 3), blur40), refused);
      expect(
        convert(
          pngWith(3000, 3000, 1),
          blur40,
          within: const Duration(seconds: 10),
        ),
        converted,
      );
    });

    test('a 1-bit image is blurred as 8 bits', () {
      final oneBit = img.encodePng(
        img.Image(width: 64, height: 64, format: img.Format.uint1),
      );
      final blurred = convert(oneBit, {
        'blur': [4],
        'format': ['png'],
      });
      expect(img.decodePng(blurred! as Uint8List)!.format, img.Format.uint8);
      // Without blur the PNG written was 8-bit already, as before.
      final unchanged = convert(oneBit, {
        'format': ['png'],
      });
      expect(img.decodePng(unchanged! as Uint8List)!.format, img.Format.uint8);
    });

    test('a 16-bit image converts to a GIF', () {
      // Varied 16-bit colors: flat ones never reach what the GIF encoder
      // cannot take.
      final image = img.Image(width: 64, height: 64, format: img.Format.uint16);
      var seed = 7;
      for (final p in image) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        p
          ..r = seed % 65536
          ..g = (seed >> 3) % 65536
          ..b = (seed >> 6) % 65536;
      }
      final out = convert(img.encodePng(image), {
        'format': ['gif'],
      });
      expect(out, converted);
      expect(img.decodeGif(out! as Uint8List)!.width, 64);
    });

    test('a 16-bit image counts eleven times an 8-bit one', () {
      // 1 MP at radius 8: 8 million, 88 million counted for 16 bits.
      expect(
        convert(png16(1000, 1000), {
          'blur': [16],
        }),
        refused,
      );
      expect(
        convert(png(1000, 1000), {
          'blur': [16],
        }),
        converted,
      );
      // 0.49 MP at radius 8: 43 million counted.
      expect(
        convert(png16(700, 700), {
          'blur': [16],
        }, within: const Duration(seconds: 5)),
        converted,
      );
    });

    test('still images and animations have separate budgets', () {
      final still = png(1600, 1000);
      expect(
        convert(still, {
          'blur': [100],
        }, within: const Duration(seconds: 10)),
        converted,
      );
      expect(
        convert(png(1601, 1000), {
          'blur': [100],
        }),
        refused,
      );

      Uint8List animation(int frames) {
        final image = img.Image(width: 100, height: 100);
        for (var i = 1; i < frames; i++) {
          image.addFrame(img.Image(width: 100, height: 100));
        }
        return img.encodeGif(image);
      }

      expect(
        convert(animation(100), {
          'blur': [40],
        }, within: const Duration(seconds: 10)),
        converted,
      );
      expect(
        convert(animation(101), {
          'blur': [40],
        }),
        refused,
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a resize before blur reduces its work; the reverse does not', () {
      final source = png(2000, 1000);
      expect(
        convert(source, {
          'width': [1000],
          'blur': [82],
        }, within: const Duration(seconds: 10)),
        converted,
      );
      expect(
        convert(source, {
          'blur': [82],
          'width': [1000],
        }),
        refused,
      );
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  test('non-positive manipulation dimensions have one public error', () {
    const message = 'Image manipulation dimensions must be greater than zero.';
    final source = png(10, 10);
    for (final manipulations in <Map<String, List<Object?>>>[
      {
        'width': [0],
      },
      {
        'height': [-1],
      },
      {
        'fit': ['crop', 0, 10],
      },
      {
        'fit': ['stretch', 10, 0],
      },
      {
        'crop': [0, 10, 'center'],
      },
      {
        'crop': [10, -1, 'center'],
      },
    ]) {
      final outcome = convert(source, manipulations);
      expect(outcome.runtimeType, ImageConversionException);
      expect((outcome! as ImageConversionException).message, message);
    }
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

    test('a second frame header after the first scan is not converted', () {
      // The first frame is 64 x 48; a second header of 8 000 x 5 000 comes
      // after the first scan, where every byte is looked at (and where the
      // decoder reads it as a second frame).
      expect(convert(_scansOnly(64, 48, 17), {}), isNot(refused));
      expect(
        convert(
          _scansOnly(64, 48, 17, afterFirstScan: _frameHeader(8000, 5000)),
          {},
        ),
        isNot(converted),
      );
    });

    // What a segment before the first scan carries is skipped by its
    // length, as a decoder skips it.
    for (final (segment, marker) in [('APP1', 0xE1), ('COM', 0xFE)]) {
      test('20 FF DA pairs inside $segment do not count as scans', () {
        final inside = [
          for (var i = 0; i < 20; i++) ...[0xFF, 0xDA, 0x00],
        ];
        expect(
          convert(_scansOnly(8000, 5000, 1, segment: (marker, inside)), {}),
          isNot(refused),
        );
      });

      test(
        'a frame header inside $segment before the first scan is skipped',
        () {
          expect(
            convert(
              _scansOnly(
                64,
                48,
                17,
                segment: (marker, _frameHeader(8000, 5000)),
              ),
              {},
            ),
            isNot(refused),
          );
        },
      );
    }

    // `FF 00` is no marker: the decoder passes over it and reads the
    // segment after it (`FF FE 00 02`, an empty comment), so the walk does.
    const stuffed = [0xFF, 0x00, 0xFF, 0xFE, 0x00, 0x02];
    for (final (name, afterStart, beforeScans) in [
      ('once before the frame header', stuffed, const <int>[]),
      ('chained before the frame header', [...stuffed, ...stuffed], <int>[]),
      ('once before the first scan', const <int>[], stuffed),
      ('chained before the first scan', <int>[], [...stuffed, ...stuffed]),
      ('alone before the frame header', [0xFF, 0x00], <int>[]),
      ('between fill bytes', [0xFF, 0xFF, 0x00, 0xFF], <int>[]),
    ]) {
      test('FF 00 $name: the scans still count', () {
        expect(
          convert(
            _scansOnly(
              8000,
              5000,
              17,
              afterStart: afterStart,
              beforeScans: beforeScans,
            ),
            {},
          ),
          refused,
        );
      });
    }

    test('the walk counts at least the scans the decoder reads (500 random '
        'headers)', () {
      // An 8 x 8 progressive JPEG of 1 001 scans: the decoder stops at its
      // 1 001st ('Too many JPEG scans'), so reaching it shows it read them
      // all, and the walk must count at least as many. Random pieces go
      // after the start of image or before the first scan.
      final random = Random(406);
      final body = _progressiveJpeg(8, 8, 1001).sublist(2);
      final firstScan = _indexOf(body, const [0xFF, 0xDA]);
      List<int> content() => [
        for (var i = random.nextInt(12); i > 0; i--)
          ...switch (random.nextInt(6)) {
            0 => const [0xFF, 0xDA],
            1 => const [0xFF, 0xC2],
            2 => const [0xFF, 0x00],
            3 => const [0xFF, 0xD9],
            4 => const [0xFF],
            _ => [random.nextInt(255)],
          },
      ];
      List<int> piece() {
        switch (random.nextInt(11)) {
          case 0:
            return const [0xFF, 0x00];
          case 1:
            return stuffed;
          case 2:
            return const [0xFF];
          case 3:
            return [0xFF, 0xD0 + random.nextInt(8)];
          case 4:
            return const [0xFF, 0x01];
          case 5:
            return [random.nextInt(255)];
          case 6:
            return const [0xFF, 0xDD, 0x00, 0x04, 0x00, 0x00];
          case 7:
            return [0xFF, 0xDC + random.nextInt(4), 0x00, 0x02];
          case 8:
            return [0xFF, 0xF0 + random.nextInt(14), 0x00, 0x02];
          default:
            final inside = content();
            final marker = random.nextBool() ? 0xFE : 0xE0 + random.nextInt(16);
            return [0xFF, marker, ..._be16(2 + inside.length), ...inside];
        }
      }

      var decoderReadAll = 0;
      for (var i = 0; i < 500; i++) {
        final header = [
          for (var k = 1 + random.nextInt(4); k > 0; k--) ...piece(),
        ];
        final bytes = Uint8List.fromList(
          random.nextBool()
              ? [0xFF, 0xD8, ...header, ...body]
              : [
                  0xFF,
                  0xD8,
                  ...body.sublist(0, firstScan),
                  ...header,
                  ...body.sublist(firstScan),
                ],
        );
        var readAll = false;
        try {
          img.JpegDecoder().decode(bytes);
        } on img.ImageException catch (e) {
          readAll = e.message == 'Too many JPEG scans';
        } on Object {
          // Refused otherwise: the decoder read fewer.
        }
        if (readAll) {
          decoderReadAll++;
          final pieces = header.map((b) => b.toRadixString(16)).join(' ');
          final (scans, _, _) = jpegScanBound(bytes, 8, 8, 40000000);
          expect(scans, greaterThanOrEqualTo(1001), reason: pieces);
          // And so the conversion refuses it before decoding: at a limit
          // of 1 000 pixels an 8 x 8 frame allows 250 scans (or the
          // decoder's own check of the file refuses it first), never by
          // the decoder's 'Too many JPEG scans' after decoding 1 000.
          expect(
            () => convertImageSync(bytes, {}, maxPixels: 1000),
            throwsA(
              isA<ImageConversionException>().having(
                (e) => e.message,
                'message',
                anyOf(
                  startsWith('The JPEG holds up to'),
                  startsWith('The file is not a JPEG'),
                ),
              ),
            ),
            reason: pieces,
          );
        }
      }
      print('the decoder read all 1 001 scans of $decoderReadAll of 500');
      // The comparison ran on enough files to mean something.
      expect(decoderReadAll, greaterThan(100));
    });

    test('an EXIF thumbnail (a JPEG inside APP1) is not counted with the '
        'image', () {
      // 16 scans is what 8 000 x 5 000 allows; the thumbnail has 16 more.
      final thumbnail = _scansOnly(160, 120, 16);
      final exif = [...'Exif'.codeUnits, 0, 0, ...thumbnail];
      expect(
        convert(_scansOnly(8000, 5000, 16, segment: (0xE1, exif)), {}),
        isNot(refused),
      );
      // The image's own scans still count: one more is refused.
      expect(
        convert(_scansOnly(8000, 5000, 17, segment: (0xE1, exif)), {}),
        refused,
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

/// Where [part] first appears in [bytes].
int _indexOf(List<int> bytes, List<int> part) {
  for (var i = 0; i + part.length <= bytes.length; i++) {
    var found = true;
    for (var k = 0; k < part.length && found; k++) {
      found = bytes[i + k] == part[k];
    }
    if (found) {
      return i;
    }
  }
  return -1;
}

/// A JPEG header of [width] x [height] followed by [scans] empty scans: the
/// count is checked before anything is decoded. [afterStart] (bytes) goes
/// right after the start of image, [segment] (a marker and its content)
/// after the frame header, [beforeScans] (bytes) right before the first
/// scan, [afterFirstScan] (bytes) right after it.
Uint8List _scansOnly(
  int width,
  int height,
  int scans, {
  List<int> afterStart = const [],
  (int, List<int>)? segment,
  List<int> beforeScans = const [],
  List<int> afterFirstScan = const [],
}) => Uint8List.fromList([
  0xFF, 0xD8, //
  ...afterStart,
  0xFF, 0xDB, ..._be16(67), 0, ...List.filled(64, 1),
  ..._frameHeader(width, height),
  if (segment case (final marker, final content)) ...[
    0xFF,
    marker,
    ..._be16(2 + content.length),
    ...content,
  ],
  ...beforeScans,
  for (var i = 0; i < scans; i++) ...[
    0xFF, 0xDA, ..._be16(8), 1, 1, 0x00, 0, 0, 0x00, //
    if (i == 0) ...afterFirstScan,
  ],
  0xFF, 0xD9,
]);
