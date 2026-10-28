// Follows spatie/laravel-medialibrary and spatie/image, Copyright (c)
// Spatie bvba, MIT License: see THIRD_PARTY_NOTICES.md.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// How [Conversion.fit] fits an image into a box (spatie/image's `Fit`).
enum Fit {
  /// Within the box, aspect ratio kept; may upsize.
  contain,

  /// Within the box, aspect ratio kept; never upsizes.
  max,

  /// Like [max], then the canvas is filled up to the box.
  fill,

  /// Exactly the box, aspect ratio ignored.
  stretch,

  /// Covers the box, aspect ratio kept, the rest cropped from the center.
  crop,

  /// Like [contain], then the canvas is filled up to the box.
  fillMax,
}

/// Where [Conversion.crop] cuts from (spatie/image's `CropPosition`).
enum CropPosition {
  topLeft,
  top,
  topRight,
  left,
  center,
  right,
  bottomLeft,
  bottom,
  bottomRight,
}

/// The image formats a conversion can write. `package:image` decodes WebP
/// but has no WebP or AVIF encoder, so those are not offered.
enum ImageFormat {
  jpg('jpg'),
  png('png'),
  gif('gif'),
  bmp('bmp'),
  tiff('tiff');

  const ImageFormat(this.extension);

  final String extension;

  static ImageFormat? fromExtension(String extension) =>
      switch (extension.toLowerCase()) {
        'jpg' || 'jpeg' || 'pjpg' => jpg,
        'png' => png,
        'gif' => gif,
        'bmp' => bmp,
        'tif' || 'tiff' => tiff,
        _ => null,
      };
}

/// A conversion (Spatie's `Conversion`): a name and the manipulations that
/// make it from the original image.
///
/// Manipulations run in the order they are first set, as Spatie's
/// `Manipulations` applies them, and each one acts on the result of the
/// previous: `width(200).height(200)` resizes to a width of 200, then that
/// result to a height of 200. Use [fit] to fit an image into a box.
///
/// Like Spatie, a conversion writes a JPEG unless [format] or
/// [keepOriginalImageFormat] says otherwise.
final class Conversion {
  Conversion(this.name);

  final String name;

  final Map<String, List<Object?>> _manipulations = {
    'format': ['jpg'],
  };
  final List<String> _collections = [];
  bool? _queued;
  bool _keepOriginalImageFormat = false;

  /// Resizes to [width], height following the aspect ratio.
  Conversion width(int width) => _set('width', [width]);

  /// Resizes to [height], width following the aspect ratio.
  Conversion height(int height) => _set('height', [height]);

  /// Fits the image into [width] × [height] the way [fit] says.
  Conversion fit(Fit fit, [int? width, int? height]) =>
      _set('fit', [fit.name, width, height]);

  /// Cuts [width] × [height] out of the image at [position].
  Conversion crop(
    int width,
    int height, [
    CropPosition position = CropPosition.center,
  ]) => _set('crop', [width, height, position.name]);

  /// The encoder quality, 1 to 100 (JPEG). Spatie leaves it to GD, whose
  /// default is 75.
  Conversion quality(int quality) => _set('quality', [quality]);

  Conversion format(ImageFormat format) => _set('format', [format.extension]);

  Conversion greyscale() => _set('greyscale', const []);

  /// Blurs by [amount], 0 to 100.
  Conversion blur(int amount) => _set('blur', [amount]);

  /// Keeps a JPEG, PNG or GIF original's format instead of [format].
  Conversion keepOriginalImageFormat() {
    _keepOriginalImageFormat = true;
    return this;
  }

  /// Only for media of these collections; every collection when none.
  Conversion performOnCollections(List<String> collections) {
    _collections.addAll(collections);
    return this;
  }

  /// Runs on the queue (Spatie's `queued()`).
  Conversion queued() {
    _queued = true;
    return this;
  }

  /// Runs while the file is added (Spatie's `nonQueued()`).
  Conversion nonQueued() {
    _queued = false;
    return this;
  }

  /// Whether it runs on the queue; [byDefault] is
  /// `QUEUE_CONVERSIONS_BY_DEFAULT` when neither [queued] nor [nonQueued]
  /// was called.
  bool shouldBeQueued(bool byDefault) => _queued ?? byDefault;

  bool shouldBePerformedOn(String collection) =>
      _collections.isEmpty ||
      _collections.contains('*') ||
      _collections.contains(collection);

  /// The manipulations as Spatie stores them, in order.
  Map<String, List<Object?>> get manipulations => {
    for (final entry in _manipulations.entries)
      entry.key: List.unmodifiable(entry.value),
  };

  /// The extension of the converted file for an original with
  /// [originalExtension] (Spatie's `getResultExtension()`).
  String resultExtension(String originalExtension) {
    if (_keepOriginalImageFormat &&
        const [
          'jpg',
          'jpeg',
          'pjpg',
          'png',
          'gif',
          'webp',
          'avif',
        ].contains(originalExtension.toLowerCase())) {
      // A WebP or AVIF original is kept in name only by Spatie's GD
      // driver; here the bytes would be JPEG, so name them so.
      return ImageFormat.fromExtension(originalExtension) == null
          ? 'jpg'
          : originalExtension;
    }
    final format = _manipulations['format']?.firstOrNull;
    return format is String && format.isNotEmpty ? format : originalExtension;
  }

  /// `<file name without extension>-<name>.<extension>` (Spatie's
  /// `DefaultFileNamer` and `getConversionFile()`).
  String fileName(String originalFileName) {
    final dot = originalFileName.lastIndexOf('.');
    final base = dot <= 0
        ? originalFileName
        : originalFileName.substring(0, dot);
    final extension = dot <= 0 ? '' : originalFileName.substring(dot + 1);
    final result = resultExtension(extension);
    return result.isEmpty ? '$base-$name' : '$base-$name.$result';
  }

  Conversion _set(String name, List<Object?> arguments) {
    _manipulations[name] = arguments;
    return this;
  }
}

/// Thrown when an image cannot be decoded or a manipulation is invalid.
final class ImageConversionException implements Exception {
  const ImageConversionException(this.message);
  final String message;

  @override
  String toString() => 'ImageConversionException: $message';
}

/// Whether `package:image` can decode files of [mimeType] or with
/// [extension] (JPEG, PNG, GIF, WebP, BMP, TIFF).
bool canConvert({String? mimeType, String? extension}) {
  const mimes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/x-ms-bmp',
    'image/tiff',
  };
  if (mimeType != null && mimes.contains(mimeType.toLowerCase())) {
    return true;
  }
  return extension != null &&
      (ImageFormat.fromExtension(extension) != null ||
          extension.toLowerCase() == 'webp');
}

/// Applies [manipulations] (from [Conversion.manipulations]) to the image
/// in [bytes] and encodes the result, in a separate isolate so decoding and
/// resizing do not hold up the event loop.
Future<Uint8List> convertImage(
  Uint8List bytes,
  Map<String, List<Object?>> manipulations,
) => Isolate.run(() => convertImageSync(bytes, manipulations));

/// [convertImage] on the calling isolate.
Uint8List convertImageSync(
  Uint8List bytes,
  Map<String, List<Object?>> manipulations,
) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const ImageConversionException('The file is not a known image.');
  }
  // Camera photos carry their rotation in EXIF; apply it, as Spatie's
  // drivers do on load.
  var image = img.bakeOrientation(decoded);
  int? quality;
  var format = 'jpg';
  for (final MapEntry(key: name, value: args) in manipulations.entries) {
    switch (name) {
      case 'width':
        image = _width(image, args[0]! as int);
      case 'height':
        image = _height(image, args[0]! as int);
      case 'fit':
        image = _fit(
          image,
          Fit.values.byName(args[0]! as String),
          args[1] as int?,
          args[2] as int?,
        );
      case 'crop':
        image = _crop(
          image,
          args[0]! as int,
          args[1]! as int,
          CropPosition.values.byName(args[2]! as String),
        );
      case 'quality':
        quality = args[0]! as int;
      case 'format':
        format = args[0]! as String;
      case 'greyscale':
        image = img.grayscale(image);
      case 'blur':
        final amount = (args[0]! as int).clamp(0, 100);
        if (amount > 0) {
          image = img.gaussianBlur(image, radius: math.max(1, amount ~/ 2));
        }
      default:
        throw ImageConversionException('Unknown manipulation [$name].');
    }
  }
  return switch (ImageFormat.fromExtension(format)) {
    ImageFormat.png => img.encodePng(image),
    ImageFormat.gif => img.encodeGif(image),
    ImageFormat.bmp => img.encodeBmp(image),
    ImageFormat.tiff => img.encodeTiff(image),
    // GD's default JPEG quality when none is set.
    ImageFormat.jpg || null => img.encodeJpg(image, quality: quality ?? 75),
  };
}

double _aspect(img.Image image) => image.width / image.height;

/// spatie/image's `width()`: the height follows the aspect ratio.
img.Image _width(img.Image image, int width) =>
    _resize(image, width, math.max(1, (width / _aspect(image)).round()));

/// spatie/image's `height()`: the width follows the aspect ratio.
img.Image _height(img.Image image, int height) =>
    _resize(image, math.max(1, (height * _aspect(image)).round()), height);

img.Image _resize(img.Image image, int width, int height) =>
    width == image.width && height == image.height
    ? image
    : img.copyResize(
        image,
        width: width,
        height: height,
        interpolation: img.Interpolation.cubic,
      );

/// spatie/image's `Fit::calculateSize()` and `Size::resize()`.
(int, int) _size(
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

img.Image _fit(img.Image image, Fit fit, int? width, int? height) {
  final desiredWidth = width ?? image.width;
  final desiredHeight = height ?? image.height;
  switch (fit) {
    case Fit.crop:
      // spatie/image's fitCrop(): scale on the side that covers the box,
      // then a centered canvas of the box.
      final originalAspect = _aspect(image);
      var result = image;
      if (image.width < desiredWidth || image.height < desiredHeight) {
        result = desiredWidth < desiredHeight
            ? _height(result, desiredHeight)
            : _width(result, desiredWidth);
      }
      result = originalAspect > desiredWidth / desiredHeight
          ? _height(result, desiredHeight)
          : _width(result, desiredWidth);
      return _canvas(result, desiredWidth, desiredHeight);
    case Fit.fillMax:
      if (width == null || height == null) {
        throw const ImageConversionException(
          'Fit.fillMax needs a width and a height.',
        );
      }
      final (w, h) = _size(
        image.width,
        image.height,
        width,
        height,
        preserveAspect: true,
        doNotUpsize: false,
      );
      return _canvas(_resize(image, w, h), width, height);
    case Fit.contain || Fit.max || Fit.fill || Fit.stretch:
      final (w, h) = fit == Fit.stretch
          ? (desiredWidth, desiredHeight)
          : _size(
              image.width,
              image.height,
              desiredWidth,
              desiredHeight,
              preserveAspect: true,
              doNotUpsize: fit != Fit.contain,
            );
      final resized = _resize(image, w, h);
      return fit == Fit.fill
          ? _canvas(resized, desiredWidth, desiredHeight)
          : resized;
  }
}

/// spatie/image's `resizeCanvas()` centered: [image] on a white canvas of
/// [width] × [height], cut where it is larger.
img.Image _canvas(img.Image image, int width, int height) {
  if (image.width == width && image.height == height) {
    return image;
  }
  final cut = _crop(image, width, height, CropPosition.center);
  if (cut.width == width && cut.height == height) {
    return cut;
  }
  final canvas = img.Image(
    width: width,
    height: height,
    numChannels: math.max(3, cut.numChannels),
  );
  img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));
  return img.compositeImage(
    canvas,
    cut,
    dstX: (width - cut.width) ~/ 2,
    dstY: (height - cut.height) ~/ 2,
  );
}

/// spatie/image's `crop()` with its `calculateCropOffsets()`.
img.Image _crop(img.Image image, int width, int height, CropPosition position) {
  final w = math.min(width, image.width);
  final h = math.min(height, image.height);
  final dx = image.width - w;
  final dy = image.height - h;
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
  return img.copyCrop(image, x: x, y: y, width: w, height: h);
}
