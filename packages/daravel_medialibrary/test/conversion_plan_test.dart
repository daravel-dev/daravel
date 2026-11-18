import 'dart:math';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
// The conversion's own plan; not exported.
import 'package:daravel_medialibrary/src/conversion_plan.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// The steps a conversion plans from an image's header are the steps it
/// runs: for random images and manipulations, what it writes has the size,
/// frames and pixels the plan says. And the estimate of their work is a
/// finite, non-negative number whatever the sizes.
void main() {
  img.Image build(Random random, PixelKind kind, int w, int h, int frames) {
    img.Image one() {
      final image = switch (kind) {
        PixelKind.palette8 => img.Image(width: w, height: h, withPalette: true),
        PixelKind.lowBit => img.Image(
          width: w,
          height: h,
          format: img.Format.uint4,
          withPalette: true,
        ),
        _ => img.Image(
          width: w,
          height: h,
          numChannels: kind.channels,
          format: kind.is16 ? img.Format.uint16 : img.Format.uint8,
        ),
      };
      for (final p in image) {
        if (image.hasPalette) {
          p.index = random.nextInt(image.palette!.numColors);
        } else {
          p.r = random.nextInt(p.maxChannelValue.toInt() + 1);
        }
      }
      return image;
    }

    final first = one();
    for (var i = 1; i < frames; i++) {
      first.addFrame(one());
    }
    return first;
  }

  Map<String, List<Object?>> manipulations(Random random) {
    final out = <String, List<Object?>>{};
    final names = ['width', 'height', 'fit', 'crop', 'greyscale', 'blur']
      ..shuffle(random);
    for (final name in names.take(1 + random.nextInt(4))) {
      out[name] = switch (name) {
        'width' || 'height' => [1 + random.nextInt(90)],
        'fit' => [
          Fit.values[random.nextInt(Fit.values.length)].name,
          1 + random.nextInt(90),
          1 + random.nextInt(90),
        ],
        'crop' => [
          1 + random.nextInt(90),
          1 + random.nextInt(90),
          CropPosition.values[random.nextInt(CropPosition.values.length)].name,
        ],
        'blur' => [random.nextInt(8)],
        _ => const <Object?>[],
      };
    }
    out['format'] = ['png'];
    return out;
  }

  test('what a conversion writes has the size, frames and pixels its plan '
      'says (400 random cases)', () {
    final random = Random(406);
    const kinds = [
      PixelKind.gray8,
      PixelKind.rgb8,
      PixelKind.rgba8,
      PixelKind.rgb16,
      PixelKind.palette8,
    ];
    var compared = 0;
    for (var i = 0; i < 400; i++) {
      final kind = kinds[random.nextInt(kinds.length)];
      final w = 1 + random.nextInt(60);
      final h = 1 + random.nextInt(60);
      final m = manipulations(random);
      final input = img.encodePng(build(random, kind, w, h, 1));
      final decodedKind = kindOfImage(img.decodePng(input)!);
      final shape = (width: w, height: h, frames: 1, kind: decodedKind!);
      List<ConversionStep> plan;
      try {
        plan = planConversion(shape, m, growth: 10000000, maxSide: 65535);
      } on ImageConversionException {
        continue;
      }
      final out = img.decodePng(convertImageSync(input, m))!;
      final last = plan.last.shape;
      final reason = 'case $i: $kind ${w}x$h $m';
      expect(
        (out.width, out.height),
        (last.width, last.height),
        reason: reason,
      );
      expect(kindOfImage(out), last.kind, reason: reason);
      compared++;
    }
    expect(compared, greaterThan(300));
  });

  test('the frames of an animation follow the plan', () {
    final random = Random(1);
    for (var i = 0; i < 40; i++) {
      final frames = 2 + random.nextInt(4);
      final w = 1 + random.nextInt(40);
      final h = 1 + random.nextInt(40);
      final m = manipulations(random)..['format'] = ['gif'];
      final input = img.encodeGif(build(random, PixelKind.rgb8, w, h, frames));
      final shape = (
        width: w,
        height: h,
        frames: frames,
        kind: PixelKind.palette8,
      );
      List<ConversionStep> plan;
      try {
        plan = planConversion(shape, m, growth: 10000000, maxSide: 65535);
      } on ImageConversionException {
        continue;
      }
      final out = img.decodeGif(convertImageSync(input, m))!;
      final last = plan.last.shape;
      expect(
        (out.width, out.height, out.numFrames),
        (last.width, last.height, frames),
        reason: 'case $i: ${w}x$h x $frames $m',
      );
    }
  });

  test('the estimate is finite and non-negative at the largest sizes', () {
    for (final kind in PixelKind.values) {
      for (final frames in [1, 1000, 1 << 30]) {
        final shape = (width: 65535, height: 65535, frames: frames, kind: kind);
        final plan = planConversion(
          shape,
          {
            'format': ['png'],
          },
          growth: 1 << 62,
          maxSide: 65535,
        );
        final work = conversionCost(ImageContainer.png, shape, plan);
        if (work != null) {
          expect(work.isFinite, isTrue, reason: '$kind $frames');
          expect(work, greaterThan(0), reason: '$kind $frames');
          // Past the default budget: refused.
          expect(
            work,
            greaterThan(MediaLibraryConfig.defaultMaxConversionWork),
          );
        }
      }
    }
  });

  test('every step at the largest sizes and frame counts: finite, '
      'positive, or refused (null); never NaN, never wrapped', () {
    // Terms are products of a side (at most 65 535), a side, frames (an
    // int) and a coefficient, as doubles: at most about 4.3e9 x 2^62 x
    // 1e4 / 1e6, far inside a double's range; a double never wraps.
    final chains = <Map<String, List<Object?>>>[
      {
        'width': [65535],
        'blur': [100],
        'greyscale': [],
        'format': ['gif'],
      },
      {
        'fit': ['fill', 65535, 65535],
        'crop': [65535, 65535, 'bottomRight'],
        'format': ['jpg'],
        'quality': [100],
      },
      {
        'blur': [100],
        'fit': ['fillMax', 65535, 65535],
        'format': ['png'],
      },
    ];
    for (final kind in PixelKind.values) {
      for (final frames in [1, 1000, 1 << 30, 1 << 62]) {
        for (final container in ImageContainer.values) {
          for (final manipulations in chains) {
            final shape = (
              width: 65535,
              height: 65535,
              frames: frames,
              kind: kind,
            );
            final List<ConversionStep> plan;
            try {
              plan = planConversion(
                shape,
                manipulations,
                growth: 1 << 62,
                maxSide: 65535,
              );
            } on ImageTooLargeException {
              // Refused by the growth limit, before any cost: also safe.
              continue;
            }
            final work = conversionCost(container, shape, plan, orient: true);
            final reason = '$kind $frames $container $manipulations';
            if (work != null) {
              expect(work.isNaN, isFalse, reason: reason);
              expect(work.isFinite, isTrue, reason: reason);
              expect(work, greaterThan(0), reason: reason);
            }
          }
        }
      }
    }
  });

  test('the estimate grows with the sides and the frames: it never wraps '
      'around to look small', () {
    // Pixels strictly growing: the sides double up to 65 535, then the
    // frames grow to 2^62.
    final sizes = [
      for (var side = 1; side < 65535; side = side * 2 + 1) (side, 1),
      for (final frames in [1, 2, 1 << 20, 1 << 40, 1 << 62]) (65535, frames),
    ];
    for (final kind in [PixelKind.rgb8, PixelKind.rgba16, PixelKind.palette8]) {
      var previous = 0.0;
      for (final (side, frames) in sizes) {
        final shape = (width: side, height: side, frames: frames, kind: kind);
        final plan = planConversion(
          shape,
          {
            'blur': [50],
          },
          growth: 1 << 62,
          maxSide: 65535,
        );
        final work = conversionCost(ImageContainer.png, shape, plan)!;
        expect(work, greaterThan(previous), reason: '$kind $side $frames');
        previous = work;
      }
    }
  });

  test('a kind without measured costs is refused, not given a cheap one', () {
    final shape = (width: 10, height: 10, frames: 1, kind: PixelKind.rgb16);
    // A 16-bit GIF has no row: it is made 8-bit first.
    final plan = planConversion(
      shape,
      {
        'format': ['gif'],
      },
      growth: 1000,
      maxSide: 65535,
    );
    expect(plan.whereType<ToEightBit>(), isNotEmpty);
    expect(conversionCost(ImageContainer.png, shape, plan), isNotNull);
    // Decoding a BMP of 16 bits per sample has no row: refused.
    expect(conversionCost(ImageContainer.bmp, shape, const []), isNull);
  });

  test('a manipulated 16-bit image is made 8-bit first; one only written '
      'keeps its 16 bits', () {
    final png16 = img.encodePng(
      img.Image(width: 8, height: 8, format: img.Format.uint16),
    );
    final resized = img.decodePng(
      convertImageSync(png16, {
        'width': [4],
        'format': ['png'],
      }),
    )!;
    expect(resized.format, img.Format.uint8);
    final kept = img.decodePng(
      convertImageSync(png16, {
        'format': ['png'],
      }),
    )!;
    expect(kept.format, img.Format.uint16);
  });
}
