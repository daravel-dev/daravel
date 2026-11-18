import 'dart:math';
import 'dart:typed_data';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
// The walk the conversion follows before decoding; not exported.
import 'package:daravel_medialibrary/src/conversion_plan.dart';
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
  /// Converts [bytes] with [manipulations]; a refusal taking longer than
  /// [within] fails the test, since each refusal here comes before any
  /// large image is made. A conversion that runs is not timed: its time
  /// is the machine's, and the work budget is checked against the model
  /// ([cost]), not against a clock.
  Object? convert(
    Uint8List bytes,
    Map<String, List<Object?>> manipulations, {
    int maxPixels = MediaLibraryConfig.defaultMaxImagePixels,
    int maxWork = MediaLibraryConfig.defaultMaxConversionWork,
    Duration within = const Duration(seconds: 2),
  }) {
    final watch = Stopwatch()..start();
    Object? outcome;
    try {
      outcome = convertImageSync(
        bytes,
        manipulations,
        maxPixels: maxPixels,
        maxWork: maxWork,
      );
    } on ImageConversionException catch (error) {
      outcome = error;
      expect(watch.elapsed, lessThan(within), reason: '$manipulations');
    }
    return outcome;
  }

  /// The work units the conversion estimates for [manipulations] of an
  /// image of [shape] stored as [container].
  double cost(
    ImageContainer container,
    ImageShape shape,
    Map<String, List<Object?>> manipulations,
  ) => conversionCost(
    container,
    shape,
    planConversion(
      shape,
      manipulations,
      growth: MediaLibraryConfig.defaultMaxImagePixels ~/ 4,
      maxSide: 65535,
    ),
    orient: true,
  )!;

  /// A budget no image here reaches, for tests of another limit.
  const unbounded = 1 << 40;

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

    // The work of writing a GIF of [frames] frames (the plan the
    // conversion runs, and its cost).
    double gifWork(int frames) {
      final shape = (
        width: 20,
        height: 20,
        frames: frames,
        kind: PixelKind.palette8,
      );
      return conversionCost(
        ImageContainer.gif,
        shape,
        planConversion(
          shape,
          {
            'format': ['gif'],
          },
          growth: 10000000,
          maxSide: 65535,
        ),
        orient: true,
      )!;
    }

    test('an animation within the work budget is written; one unit less '
        'is refused before decoding', () {
      final work = gifWork(1000).ceil();
      expect(
        convertImageSync(animation(1000), {
          'format': ['gif'],
        }, maxWork: work),
        converted,
      );
      expect(
        () => convertImageSync(animation(1000), {
          'format': ['gif'],
        }, maxWork: work - 1),
        throwsA(isA<ImageTooLargeException>()),
      );
    });

    test('writing a GIF counts its encoding: a budget a JPEG of the same '
        'enlargement fits refuses the GIF before encoding', () {
      final small = png(100, 100);
      const shape = (width: 100, height: 100, frames: 1, kind: PixelKind.rgb8);
      final asGif = <String, List<Object?>>{
        'width': [1500],
        'format': ['gif'],
      };
      final asJpeg = <String, List<Object?>>{
        'width': [1500],
      };
      final jpeg = cost(ImageContainer.png, shape, asJpeg).ceil();
      expect(cost(ImageContainer.png, shape, asGif), greaterThan(jpeg * 2));
      expect(convert(small, asGif, maxWork: jpeg), refused);
      expect(convert(small, asJpeg, maxWork: jpeg), converted);
    });
  });

  group('one work budget for the whole conversion', () {
    ImageShape shape(int width, int height, PixelKind kind, [int frames = 1]) =>
        (width: width, height: height, frames: frames, kind: kind);

    test('blur costs more with more channels and a larger radius', () {
      final blur = <String, List<Object?>>{
        'blur': [40],
      };
      final gray = cost(
        ImageContainer.png,
        shape(1000, 1000, PixelKind.gray8),
        blur,
      );
      final rgb = cost(
        ImageContainer.png,
        shape(1000, 1000, PixelKind.rgb8),
        blur,
      );
      final rgba = cost(
        ImageContainer.png,
        shape(1000, 1000, PixelKind.rgba8),
        blur,
      );
      expect(gray, lessThan(rgb));
      expect(rgb, lessThan(rgba));
      expect(
        cost(ImageContainer.png, shape(1000, 1000, PixelKind.rgb8), {
          'blur': [80],
        }),
        greaterThan(rgb),
      );
    });

    test('a manipulated 16-bit image is made 8-bit before its first step', () {
      final steps = planConversion(
        shape(100, 100, PixelKind.rgb16),
        {
          'blur': [10],
        },
        growth: 1 << 30,
        maxSide: 65535,
      );
      expect(steps.first, isA<ToEightBit>());
      expect(steps[1], isA<Blur>());
      expect(steps[1].shape.kind, PixelKind.rgb8);
      // Only written in another format, it keeps its 16 bits.
      final kept = planConversion(
        shape(100, 100, PixelKind.rgb16),
        {
          'format': ['png'],
        },
        growth: 1 << 30,
        maxSide: 65535,
      );
      expect(kept.single, isA<Encode>());
      expect(kept.single.shape.kind, PixelKind.rgb16);
    });

    test('every step counts every frame', () {
      for (final manipulations in <Map<String, List<Object?>>>[
        {
          'width': [50],
        },
        {
          'blur': [10],
        },
        {'greyscale': []},
        {
          'crop': [40, 40, 'center'],
        },
        {
          'fit': ['fill', 120, 80],
        },
      ]) {
        final one = cost(
          ImageContainer.gif,
          shape(100, 100, PixelKind.palette8),
          manipulations,
        );
        final ten = cost(
          ImageContainer.gif,
          shape(100, 100, PixelKind.palette8, 10),
          manipulations,
        );
        expect(ten, closeTo(one * 10, one * 1e-9), reason: '$manipulations');
      }
    });

    test('a resize before blur costs less than the reverse', () {
      final source = shape(2000, 1000, PixelKind.rgb8);
      expect(
        cost(ImageContainer.png, source, {
          'width': [1000],
          'blur': [82],
        }),
        lessThan(
          cost(ImageContainer.png, source, {
            'blur': [82],
            'width': [1000],
          }),
        ),
      );
    });

    test('at the budget an image converts; one unit less refuses it, '
        'before decoding', () {
      final bytes = png(300, 200);
      final manipulations = <String, List<Object?>>{
        'blur': [20],
        'width': [150],
      };
      final work = cost(
        ImageContainer.png,
        shape(300, 200, PixelKind.rgb8),
        manipulations,
      );
      expect(convert(bytes, manipulations, maxWork: work.ceil()), converted);
      expect(convert(bytes, manipulations, maxWork: work.ceil() - 1), refused);
    });

    test('a step with no measured cost for the pixels is not run', () {
      // BMP decoding has no row for gray pixels: refused, not guessed.
      expect(
        conversionCost(
          ImageContainer.bmp,
          shape(10, 10, PixelKind.gray8),
          const [],
        ),
        isNull,
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
      expect(
        convert(_scansOnly(8000, 5000, 16), {}, maxWork: unbounded),
        isNot(refused),
      );
      expect(
        convert(_scansOnly(8000, 5000, 17), {}, maxWork: unbounded),
        refused,
      );
      // A small image allows many more.
      expect(convert(_scansOnly(64, 48, 17), {}), isNot(refused));
    });

    test('a second frame header after the first scan is not converted', () {
      // The first frame is 64 x 48; a second header of 8 000 x 5 000 comes
      // after the first scan, where every byte is looked at.
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
    // length.
    for (final (segment, marker) in [('APP1', 0xE1), ('COM', 0xFE)]) {
      test('20 FF DA pairs inside $segment do not count as scans', () {
        final inside = [
          for (var i = 0; i < 20; i++) ...[0xFF, 0xDA, 0x00],
        ];
        expect(
          convert(
            _scansOnly(8000, 5000, 1, segment: (marker, inside)),
            {},
            maxWork: unbounded,
          ),
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

    // `FF 00` is no marker (ITU-T T.81 B.1.1.3): the segment after it
    // (`FF FE 00 02`, an empty comment) is read.
    const stuffed = [0xFF, 0x00, 0xFF, 0xFE, 0x00, 0x02];
    for (final (name, afterStart, beforeScans) in [
      ('once before the frame header', stuffed, const <int>[]),
      ('chained before the frame header', [...stuffed, ...stuffed], <int>[]),
      ('once before the first scan', const <int>[], stuffed),
      ('chained before the first scan', <int>[], [...stuffed, ...stuffed]),
      ('alone before the frame header', [0xFF, 0x00], <int>[]),
      ('between fill bytes', [0xFF, 0xFF, 0x00, 0xFF], <int>[]),
    ]) {
      test('a stuffed byte pair $name: the scans still count', () {
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
            maxWork: unbounded,
          ),
          isA<ImageTooLargeException>().having(
            (e) => e.message,
            'message',
            contains('scans'),
          ),
        );
      });
    }

    test('the walk counts at least the scans decoding reads (500 random '
        'headers)', () {
      // An 8 x 8 progressive JPEG of 1 001 scans: decoding stops at its
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
          // Refused otherwise: fewer were read.
        }
        if (readAll) {
          decoderReadAll++;
          final pieces = header.map((b) => b.toRadixString(16)).join(' ');
          final (scans, _, _) = jpegScanBound(bytes, 8, 8, 40000000);
          expect(scans, greaterThanOrEqualTo(1001), reason: pieces);
          // And so the conversion refuses it before decoding: at a limit
          // of 1 000 pixels an 8 x 8 frame allows 250 scans (or the
          // the file is refused as no JPEG first), never by decoding
          // 1 000 scans first.
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
      print('decoding read all 1 001 scans of $decoderReadAll of 500');
      // The comparison ran on enough files to mean something.
      expect(decoderReadAll, greaterThan(100));
    });

    test('an EXIF thumbnail (a JPEG inside APP1) is not counted with the '
        'image', () {
      // 16 scans is what 8 000 x 5 000 allows; the thumbnail has 16 more.
      final thumbnail = _scansOnly(160, 120, 16);
      final exif = [...'Exif'.codeUnits, 0, 0, ...thumbnail];
      expect(
        convert(
          _scansOnly(8000, 5000, 16, segment: (0xE1, exif)),
          {},
          maxWork: unbounded,
        ),
        isNot(refused),
      );
      // The image's own scans still count: one more is refused.
      expect(
        convert(
          _scansOnly(8000, 5000, 17, segment: (0xE1, exif)),
          {},
          maxWork: unbounded,
        ),
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
