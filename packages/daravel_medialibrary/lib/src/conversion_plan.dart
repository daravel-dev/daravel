/// What a conversion does, step by step, worked out from the image's
/// header before anything is decoded, and what it costs. The conversion
/// runs the same steps ([planConversion]), so the cost is that of what
/// runs. Not exported: the conversion's own, tested by its own tests.
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'conversion.dart';

/// The pixels of an image as the conversion holds them. A kind the table
/// below has no row for is not converted ([ImageShape.kind] is null).
enum PixelKind {
  gray8(1, 8, 0),
  grayAlpha8(2, 8, 1),
  rgb8(3, 8, 2),
  rgba8(4, 8, 3),
  gray16(1, 16, 4),
  grayAlpha16(2, 16, 5),
  rgb16(3, 16, 6),
  rgba16(4, 16, 7),

  /// 8-bit indexes into a palette of RGB colors.
  palette8(3, 8, 8, palette: true),

  /// 8-bit indexes into a palette of RGBA colors.
  paletteAlpha8(4, 8, 8, palette: true),

  /// 1, 2 or 4 bits of gray.
  lowBitGray(1, 4, 9),

  /// 1, 2 or 4 bits indexing a palette of RGB colors.
  lowBit(3, 4, 9, palette: true),

  /// 1, 2 or 4 bits indexing a palette of RGBA colors.
  lowBitAlpha(4, 4, 9, palette: true);

  const PixelKind(
    this.channels,
    this.bits,
    this.costRow, {
    this.palette = false,
  });

  /// The channels of a pixel (of its palette color for a palette).
  final int channels;

  /// Bits per sample: 4 stands for 1, 2 and 4.
  final int bits;

  /// The column of the cost table this kind is measured in.
  final int costRow;

  /// Whether pixels index a palette.
  final bool palette;

  /// The 8-bit kind of the same channels, without a palette.
  PixelKind get eightBit => switch (channels) {
    1 => gray8,
    2 => grayAlpha8,
    3 => rgb8,
    _ => rgba8,
  };

  bool get is16 => bits == 16;

  /// Not 8-bit samples of their own: 16 bits, low bits or a palette.
  bool get needsEightBit => bits != 8 || palette;
}

/// An image's size and pixels, as its header gives them.
typedef ImageShape = ({int width, int height, int frames, PixelKind kind});

/// One step of a conversion, with the shape it makes.
sealed class ConversionStep {
  const ConversionStep(this.shape);

  /// The image after this step.
  final ImageShape shape;
}

/// Made 8-bit (a 16-bit image, a palette or low bits spread to channels).
final class ToEightBit extends ConversionStep {
  const ToEightBit(super.shape);
}

/// Resized to [ConversionStep.shape] (cubic).
final class Resize extends ConversionStep {
  const Resize(super.shape);
}

/// Cut to [ConversionStep.shape] at [x], [y].
final class Crop extends ConversionStep {
  const Crop(super.shape, this.x, this.y);

  final int x;
  final int y;
}

/// Put centered on a white canvas of [ConversionStep.shape]; [source] is
/// what is put on it.
final class Canvas extends ConversionStep {
  const Canvas(super.shape, this.source);

  final ImageShape source;
}

final class Greyscale extends ConversionStep {
  const Greyscale(super.shape);
}

final class Blur extends ConversionStep {
  const Blur(super.shape, this.radius);

  final int radius;
}

/// Written as [format] with [quality] (JPEG).
final class Encode extends ConversionStep {
  const Encode(super.shape, this.format, this.quality);

  final ImageFormat format;
  final int? quality;
}

/// The steps a conversion of an image of [input] runs for
/// [manipulations], each with the shape it makes; refused
/// ([ImageConversionException], [ImageTooLargeException]) as the
/// conversion refuses them, before anything is decoded. A manipulation
/// makes at most [growth] pixels (all frames) with sides of at most
/// [maxSide].
List<ConversionStep> planConversion(
  ImageShape input,
  Map<String, List<Object?>> manipulations, {
  required int growth,
  required int maxSide,
}) {
  final steps = <ConversionStep>[];
  var shape = input;
  ImageShape withSize(int width, int height, [PixelKind? kind]) => (
    width: width,
    height: height,
    frames: shape.frames,
    kind: kind ?? shape.kind,
  );

  void checkDimensions(int? width, int? height) {
    if ((width != null && width <= 0) || (height != null && height <= 0)) {
      throw const ImageConversionException(
        'Image manipulation dimensions must be greater than zero.',
      );
    }
  }

  void checkTarget(int width, int height) {
    checkDimensions(width, height);
    final count = math.max(1, shape.frames);
    if (width > maxSide ||
        height > maxSide ||
        width > growth ~/ count ~/ height) {
      throw ImageTooLargeException(
        'The conversion would make a $width x $height image'
        '${count > 1 ? ' of $count frames' : ''} out of a ${shape.width} x '
        '${shape.height} one, past the limit of $growth pixels; it was not '
        'converted.',
      );
    }
  }

  double aspect() => shape.width / shape.height;

  void resize(int width, int height) {
    checkDimensions(width, height);
    if (width == shape.width && height == shape.height) {
      return;
    }
    checkTarget(width, height);
    shape = withSize(width, height);
    steps.add(Resize(shape));
  }

  void crop(int width, int height, CropPosition position) {
    checkDimensions(width, height);
    final w = math.min(width, shape.width);
    final h = math.min(height, shape.height);
    final dx = shape.width - w;
    final dy = shape.height - h;
    final (x, y) = switch (position) {
      CropPosition.topLeft => (0, 0),
      CropPosition.top => (dx ~/ 2, 0),
      CropPosition.topRight => (dx, 0),
      CropPosition.left => (0, dy ~/ 2),
      CropPosition.center => (dx ~/ 2, dy ~/ 2),
      CropPosition.right => (dx, dy ~/ 2),
      CropPosition.bottomLeft => (0, dy),
      CropPosition.bottom => (dx ~/ 2, dy),
      CropPosition.bottomRight => (dx, dy),
    };
    shape = withSize(w, h);
    steps.add(Crop(shape, x, y));
  }

  void canvas(int width, int height) {
    checkDimensions(width, height);
    checkTarget(width, height);
    if (shape.width == width && shape.height == height) {
      return;
    }
    crop(width, height, CropPosition.center);
    if (shape.width == width && shape.height == height) {
      return;
    }
    final source = shape;
    shape = withSize(
      width,
      height,
      shape.kind.channels == 4 ? PixelKind.rgba8 : PixelKind.rgb8,
    );
    steps.add(Canvas(shape, source));
  }

  void toWidth(int width) => resize(width, sideOf(width / aspect()));
  void toHeight(int height) => resize(sideOf(height * aspect()), height);

  void fit(Fit fit, int? width, int? height) {
    checkDimensions(width, height);
    final desiredWidth = width ?? shape.width;
    final desiredHeight = height ?? shape.height;
    switch (fit) {
      case Fit.crop:
        final originalAspect = aspect();
        if (shape.width < desiredWidth || shape.height < desiredHeight) {
          desiredWidth < desiredHeight
              ? toHeight(desiredHeight)
              : toWidth(desiredWidth);
        }
        originalAspect > desiredWidth / desiredHeight
            ? toHeight(desiredHeight)
            : toWidth(desiredWidth);
        canvas(desiredWidth, desiredHeight);
      case Fit.fillMax:
        if (width == null || height == null) {
          throw const ImageConversionException(
            'Fit.fillMax needs a width and a height.',
          );
        }
        final (w, h) = fitSize(
          shape.width,
          shape.height,
          width,
          height,
          preserveAspect: true,
          doNotUpsize: false,
        );
        resize(w, h);
        canvas(width, height);
      case Fit.contain || Fit.max || Fit.fill || Fit.stretch:
        final (w, h) = fit == Fit.stretch
            ? (desiredWidth, desiredHeight)
            : fitSize(
                shape.width,
                shape.height,
                desiredWidth,
                desiredHeight,
                preserveAspect: true,
                doNotUpsize: fit != Fit.contain,
              );
        resize(w, h);
        if (fit == Fit.fill) {
          canvas(desiredWidth, desiredHeight);
        }
    }
  }

  void toEightBit() {
    if (shape.kind.needsEightBit) {
      shape = withSize(shape.width, shape.height, shape.kind.eightBit);
      steps.add(ToEightBit(shape));
    }
  }

  int? quality;
  var format = 'jpg';
  // A 16-bit image that is manipulated is made 8-bit first, as GD (the
  // image driver laravel-medialibrary uses by default) holds 8 bits per
  // channel; one only written in another format keeps its 16 bits.
  const changing = {'width', 'height', 'fit', 'crop', 'greyscale', 'blur'};
  if (shape.kind.is16 && manipulations.keys.any(changing.contains)) {
    shape = withSize(shape.width, shape.height, shape.kind.eightBit);
    steps.add(ToEightBit(shape));
  }
  for (final MapEntry(key: name, value: args) in manipulations.entries) {
    switch (name) {
      case 'width':
        toWidth(args[0]! as int);
      case 'height':
        toHeight(args[0]! as int);
      case 'fit':
        fit(
          Fit.values.byName(args[0]! as String),
          args[1] as int?,
          args[2] as int?,
        );
      case 'crop':
        checkTarget(args[0]! as int, args[1]! as int);
        crop(
          args[0]! as int,
          args[1]! as int,
          CropPosition.values.byName(args[2]! as String),
        );
      case 'quality':
        quality = args[0]! as int;
      case 'format':
        format = args[0]! as String;
      case 'greyscale':
        // Low bits and a palette are made 8-bit first (greyscale would
        // spread a palette to its channels anyway); the pixels are the
        // same.
        toEightBit();
        steps.add(Greyscale(shape));
      case 'blur':
        final amount = (args[0]! as int).clamp(0, 100);
        if (amount > 0) {
          // Likewise: blurred as they are, low bits cost 10 to 50 times as
          // much.
          toEightBit();
          steps.add(Blur(shape, math.max(1, amount ~/ 2)));
        }
      default:
        throw ImageConversionException('Unknown manipulation [$name].');
    }
  }
  final output = ImageFormat.fromExtension(format) ?? ImageFormat.jpg;
  if (output == ImageFormat.gif && shape.kind.is16) {
    shape = withSize(shape.width, shape.height, shape.kind.eightBit);
    steps.add(ToEightBit(shape));
  }
  steps.add(Encode(shape, output, quality));
  return steps;
}

/// A side computed from an aspect ratio, at least 1; past the largest side
/// it is refused. A value no int holds (infinite, or past 2^53) reads as
/// 2^53, which is refused the same way.
int sideOf(double value) => value.isFinite && value < 9007199254740992
    ? math.max(1, value.round())
    : 9007199254740992;

/// spatie/image's `Fit::calculateSize()` and `Size::resize()`.
(int, int) fitSize(
  int width,
  int height,
  int desiredWidth,
  int desiredHeight, {
  required bool preserveAspect,
  required bool doNotUpsize,
}) {
  (int, int) resizeWidth((int, int) size) {
    final newWidth = doNotUpsize
        ? math.min(desiredWidth, size.$1)
        : desiredWidth;
    var newHeight = size.$2;
    if (preserveAspect) {
      final calculated = math.max(1, (newWidth / (size.$1 / size.$2)).round());
      newHeight = doNotUpsize ? math.min(calculated, size.$2) : calculated;
    }
    return (newWidth, newHeight);
  }

  (int, int) resizeHeight((int, int) size) {
    final newHeight = doNotUpsize
        ? math.min(desiredHeight, size.$2)
        : desiredHeight;
    var newWidth = size.$1;
    if (preserveAspect) {
      final calculated = math.max(1, (newHeight * (size.$1 / size.$2)).round());
      newWidth = doNotUpsize ? math.min(calculated, size.$1) : calculated;
    }
    return (newWidth, newHeight);
  }

  final original = (width, height);
  final dominantWidth = resizeWidth(resizeHeight(original));
  final dominantHeight = resizeHeight(resizeWidth(original));
  return dominantHeight.$1 <= desiredWidth && dominantHeight.$2 <= desiredHeight
      ? dominantHeight
      : dominantWidth;
}

/// How an image was stored, as far as decoding costs differ.
enum ImageContainer { jpeg, png, gif, webpLossy, webpLossless, bmp }

/// Work units per million pixels (all frames) of each step, by
/// [PixelKind] in its declaration order; null where the conversion has no
/// measured cost, and such a step is not run. PROVISIONAL: measured on a
/// developer machine; the reference figures come from the CI runner.
const Map<String, List<double?>> _perMegapixel = {
  //               g8    ga8   rgb8  rgba8 g16   ga16  rgb16 rgba16 pal8 low
  'decodePng': [10, 21, 30, 40, 30, 75, 125, 125, 10, 56],
  'decodeBmp': [null, null, 60, 110, null, null, null, null, 35, 35],
  'resize': [230, 460, 510, 650, 5200, 4650, 3500, 3500, 10, 75],
  'crop': [5, 5, 5, 5, 5, 5, 5, 5, 5, 175],
  'greyscale': [80, 215, 10, 10, 65, 75, 60, 60, 120, 355],
  'toEightBit': [0, 1, 0, 0, 145, 167, 165, 165, 120, 157],
  'blurBase': [20, 55, 40, 50, 320, 190, 230, 140, null, null],
  'blurPerRadius': [15, 40, 40, 55, 370, 390, 290, 330, null, null],
  'jpg': [125, 161, 175, 165, 302, 294, 370, 370, 215, 200],
  'png': [20, 67, 450, 450, 83, 318, 550, 550, 60, 6],
  'bmp': [10, 159, 10, 10, 100, 257, 180, 180, 5, 5],
  'tiff': [1, 1, 1, 1, 118, 149, 155, 155, 1, 1],
  'gif': [530, 1751, 1300, 1300, null, null, null, null, 40, 30],
};

/// Per million pixels of a decode that does not depend on the pixels.
const Map<ImageContainer, double> _decodePerMegapixel = {
  ImageContainer.jpeg: 170,
  ImageContainer.gif: 30,
  ImageContainer.webpLossy: 200,
  ImageContainer.webpLossless: 60,
};

/// A canvas: filling it, per million pixels of the canvas, and putting
/// the image on it, per million pixels of the image put.
const double _canvasFill = 40;
const double _canvasPut = 1000;

/// Turning a photo upright (EXIF orientation), per million pixels.
const double _orient = 50;

/// What is added to every estimate: the measured whole conversions took
/// up to this much more than the sum of their steps.
const double costMargin = 1.15;

/// The work of decoding an image of [input] from [container] (turned
/// upright when [orient]) and running [steps], in units ([costMargin]
/// included); null when a step has no measured cost for its pixels, and
/// then the conversion is refused. Every term is a finite product of
/// non-negative numbers below 2^53, summed as a double: no overflow, no
/// NaN, never negative.
double? conversionCost(
  ImageContainer container,
  ImageShape input,
  List<ConversionStep> steps, {
  bool orient = false,
}) {
  double megapixels(ImageShape s) =>
      s.width.toDouble() * s.height.toDouble() * math.max(1, s.frames) / 1e6;

  double? row(String name, PixelKind kind) =>
      _perMegapixel[name]![kind.costRow];

  var total = 0.0;
  bool add(double? perMegapixel, ImageShape s) {
    if (perMegapixel == null) {
      return false;
    }
    total += perMegapixel * megapixels(s);
    return true;
  }

  final decoded = switch (container) {
    ImageContainer.png => row('decodePng', input.kind),
    ImageContainer.bmp => row('decodeBmp', input.kind),
    _ => _decodePerMegapixel[container],
  };
  if (!add(decoded, input)) {
    return null;
  }
  if (orient) {
    add(_orient, input);
  }
  var before = input;
  for (final step in steps) {
    final s = step.shape;
    final ok = switch (step) {
      ToEightBit() => add(row('toEightBit', before.kind), before),
      Resize() => add(row('resize', s.kind), s),
      Crop() => add(row('crop', s.kind), s),
      Canvas(:final source) => add(_canvasFill, s) && add(_canvasPut, source),
      Greyscale() => add(row('greyscale', before.kind), before),
      Blur(:final radius) => () {
        final base = row('blurBase', s.kind);
        final perRadius = row('blurPerRadius', s.kind);
        return base != null &&
            perRadius != null &&
            add(base + perRadius * radius, s);
      }(),
      Encode(:final format) => add(row(format.name, s.kind), s),
    };
    if (!ok) {
      return null;
    }
    before = s;
  }
  return total * costMargin;
}

/// The kind of [image]'s pixels, or null for one without measured costs.
PixelKind? kindOfImage(img.Image image) {
  final lowBit =
      image.format == img.Format.uint1 ||
      image.format == img.Format.uint2 ||
      image.format == img.Format.uint4;
  if (image.hasPalette) {
    final alpha = image.palette!.numChannels == 4;
    if (image.format == img.Format.uint8) {
      return alpha ? PixelKind.paletteAlpha8 : PixelKind.palette8;
    }
    return lowBit ? (alpha ? PixelKind.lowBitAlpha : PixelKind.lowBit) : null;
  }
  if (lowBit) {
    return image.numChannels == 1 ? PixelKind.lowBitGray : null;
  }
  return switch ((image.format, image.numChannels)) {
    (img.Format.uint8, 1) => PixelKind.gray8,
    (img.Format.uint8, 2) => PixelKind.grayAlpha8,
    (img.Format.uint8, 3) => PixelKind.rgb8,
    (img.Format.uint8, 4) => PixelKind.rgba8,
    (img.Format.uint16, 1) => PixelKind.gray16,
    (img.Format.uint16, 2) => PixelKind.grayAlpha16,
    (img.Format.uint16, 3) => PixelKind.rgb16,
    (img.Format.uint16, 4) => PixelKind.rgba16,
    _ => null,
  };
}
