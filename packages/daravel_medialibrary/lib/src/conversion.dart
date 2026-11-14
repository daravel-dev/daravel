// Follows spatie/laravel-medialibrary and spatie/image, Copyright (c)
// Spatie bvba, MIT License: see THIRD_PARTY_NOTICES.md.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'config.dart';

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
  /// Keep the top left.
  topLeft,

  /// Keep the top.
  top,

  /// Keep the top right.
  topRight,

  /// Keep the left.
  left,

  /// Keep the center.
  center,

  /// Keep the right.
  right,

  /// Keep the bottom left.
  bottomLeft,

  /// Keep the bottom.
  bottom,

  /// Keep the bottom right.
  bottomRight,
}

/// The image formats a conversion can write. `package:image` decodes WebP
/// but has no WebP or AVIF encoder, so those are not offered.
enum ImageFormat {
  /// JPEG.
  jpg('jpg'),

  /// PNG.
  png('png'),

  /// GIF.
  gif('gif'),

  /// BMP.
  bmp('bmp'),

  /// TIFF.
  tiff('tiff');

  /// A format written with [extension].
  const ImageFormat(this.extension);

  /// The file extension.
  final String extension;

  /// The format of [extension], or null.
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
  /// A conversion named [name].
  Conversion(this.name);

  /// The conversion's name, used in URLs.
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

  /// Writes the result as [format].
  Conversion format(ImageFormat format) => _set('format', [format.extension]);

  /// Makes the image grey.
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

  /// Whether the conversion applies to files of [collection].
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
base class ImageConversionException implements Exception {
  /// An image could not be converted: [message].
  const ImageConversionException(this.message);

  /// What failed.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// An image whose header declares more pixels or frames than the media
/// library converts (`MediaLibraryConfig.maxImagePixels`,
/// `maxImageFrames`); the original stays stored, its conversions are not
/// made.
final class ImageTooLargeException extends ImageConversionException {
  /// The image was refused for [message].
  const ImageTooLargeException(super.message);
}

/// Whether files of [mimeType] or with [extension] are converted (JPEG,
/// PNG, GIF, WebP, BMP). TIFF is not, in this version: its conversions are
/// skipped and the original kept. An animated PNG or WebP is told from its
/// content when it is converted, and refused then.
bool canConvert({String? mimeType, String? extension}) {
  const mimes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/x-ms-bmp',
  };
  if (mimeType != null && mimes.contains(mimeType.toLowerCase())) {
    return true;
  }
  if (extension == null) {
    return false;
  }
  final format = ImageFormat.fromExtension(extension);
  return (format != null && format != ImageFormat.tiff) ||
      extension.toLowerCase() == 'webp';
}

/// Applies [manipulations] (from [Conversion.manipulations]) to the image
/// in [bytes] and encodes the result, in a separate isolate so decoding and
/// resizing do not hold up the event loop.
///
/// The image's size is read from its header first: one that would decode
/// to more than [maxPixels] pixels (width x height x frames) or hold more
/// than [maxFrames] frames throws [ImageTooLargeException] before anything
/// is decoded. An isolate shares its process's memory, so a small file
/// that declares 16 000 x 16 000 pixels would take gigabytes otherwise.
///
/// What is guaranteed: a still image (JPEG, PNG, WebP, BMP) or a GIF is
/// decoded by a decoder held to [maxPixels] (half of it for a WebP or a
/// 16-bit PNG), one frame for a still image; an animated PNG or WebP is not
/// converted in this version. The limit bounds an image's size, not memory
/// exactly: at the default limit, plan about 500 MiB of memory per
/// conversion running at once. Measured peaks (a compiled process):
///
/// | Image | Peak memory | Time |
/// | --- | --- | --- |
/// | baseline JPEG, 8 000 x 5 000 | about 130 MiB | 2.5 s |
/// | the same, EXIF orientation 6 | about 130 MiB | 3.5 s |
/// | progressive JPEG, 8 000 x 5 000 (with or without orientation) | about 415 MiB | 3 s |
/// | PNG, 6 324 x 6 324 | about 205 MiB | 1 s |
/// | PNG, 16-bit, 4 472 x 4 472 | about 205 MiB | 1 s |
/// | WebP, 4 472 x 4 472 | about 170 to 175 MiB | 0.3 to 0.9 s |
/// | the same, EXIF orientation 6 | about 245 MiB | 0.8 s |
/// | WebP, 4 472 x 4 472, many Huffman groups | about 395 MiB (470 with orientation) | 2.6 s |
/// | WebP of any size, even a small one | up to about 240 MiB | under 1 s |
/// | GIF, 1 000 frames of 200 x 200 | about 140 MiB | 1.2 s |
/// | GIF, 2 frames of 4 472 x 4 472 | about 110 MiB | 1 s |
Future<Uint8List> convertImage(
  Uint8List bytes,
  Map<String, List<Object?>> manipulations, {
  int maxPixels = MediaLibraryConfig.defaultMaxImagePixels,
  int maxFrames = MediaLibraryConfig.defaultMaxImageFrames,
}) => Isolate.run(
  () => convertImageSync(
    bytes,
    manipulations,
    maxPixels: maxPixels,
    maxFrames: maxFrames,
  ),
);

/// [convertImage] on the calling isolate.
Uint8List convertImageSync(
  Uint8List bytes,
  Map<String, List<Object?>> manipulations, {
  int maxPixels = MediaLibraryConfig.defaultMaxImagePixels,
  int maxFrames = MediaLibraryConfig.defaultMaxImageFrames,
}) {
  if (maxPixels < 1 || maxFrames < 1) {
    throw ArgumentError('maxPixels and maxFrames are at least 1.');
  }
  // One decoder instance reads the file once: what is checked below is
  // the decoder's own reading, and the same instance then decodes it.
  final decoder = _decoderFor(bytes, maxPixels);
  if (decoder is img.JpegDecoder) {
    _checkJpegComponents(bytes);
  }
  final info = decoder == null
      ? null
      : _guarded(() => decoder.startDecode(bytes));
  if (decoder == null || info == null) {
    throw const ImageConversionException(
      'The file is not a JPEG, PNG, GIF, WebP or BMP image (TIFF is not '
      'converted in this version).',
    );
  }
  if (_isAnimated(info)) {
    throw const ImageConversionException(
      'Animated images (PNG, WebP) are not converted in this version.',
    );
  }
  // Half the pixels for a 16-bit PNG, which decodes to two bytes per
  // sample, and for a WebP, whose measured cost per pixel is about twice a
  // JPEG's: the same memory then holds half as many of their pixels. Both
  // are the decoder's reading.
  final pixels = (info is img.PngInfo && info.bits > 8) || info is img.WebPInfo
      ? math.max(1, maxPixels ~/ 2)
      : maxPixels;
  final frames = math.max(1, info.numFrames);
  if (info.width < 1 || info.height < 1) {
    throw ImageConversionException(
      'The image declares ${info.width} x ${info.height} pixels; it was not '
      'converted.',
    );
  }
  // Divisions only: width x height x frames <= pixels, without a product
  // that could overflow.
  if (frames > maxFrames || info.width > pixels ~/ frames ~/ info.height) {
    throw ImageTooLargeException(
      'The image is ${info.width} x ${info.height} pixels in $frames '
      'frame(s), past the limit of $pixels pixels and $maxFrames frames '
      '(MEDIA_MAX_IMAGE_PIXELS, MEDIA_MAX_IMAGE_FRAMES); it was not '
      'converted.',
    );
  }
  // A still image: its one frame, from the reading checked above. An
  // animated GIF (still converted: its decoder checks every frame against
  // its screen while decoding) is decoded whole.
  final decoded = _guarded(
    () => decoder is img.GifDecoder && frames > 1
        ? decoder.decode(bytes)
        : decoder.decodeFrame(0),
  );
  if (decoded == null) {
    throw const ImageConversionException('The file is not a known image.');
  }
  // Camera photos carry their rotation in EXIF; apply it, as Spatie's
  // drivers do on load. Only when there is one to apply: baking copies the
  // whole image.
  var image = (decoded.exif.imageIfd.orientation ?? 1) == 1
      ? decoded
      : img.bakeOrientation(decoded);
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

/// The decoder of [bytes] among the formats [canConvert] names (JPEG, PNG,
/// GIF, WebP, BMP; detected from the content in
/// `findDecoderForData`'s order), holding its decode to [maxPixels]
/// across all frames or pages; `null` for any other content.
/// `findDecoderForData` would also take TIFF, PSD, EXR, PNM, TGA, ICO and
/// PVR whatever the file's name; only the formats this library limits
/// and tests are decoded.
img.Decoder? _decoderFor(Uint8List bytes, int maxPixels) {
  final candidates = <img.Decoder>[
    img.JpegDecoder(maxPixels: maxPixels),
    img.PngDecoder(maxPixels: maxPixels),
    img.GifDecoder()..maxPixels = maxPixels,
    img.WebPDecoder()..maxPixels = maxPixels,
    img.BmpDecoder(maxPixels: maxPixels),
  ];
  for (final decoder in candidates) {
    if (decoder.isValidFile(bytes)) {
      return decoder;
    }
  }
  return null;
}

/// [body], with `package:image`'s errors as this library's: its pixel
/// budget (checked per frame and over all frames or pages, with our
/// limit) as [ImageTooLargeException], a damaged file as
/// [ImageConversionException]. The budget error is told by its message,
/// which `package:image` does not type. Our own checks run first, on what
/// the header read reports; the package's own budget still covers what
/// only decoding reaches. Should that message change, such a file becomes
/// an [ImageConversionException]: still refused, only named differently.
T _guarded<T>(T Function() body) {
  try {
    return body();
  } on img.ImageException catch (error) {
    throw error.message.contains('exceed the maximum')
        ? ImageTooLargeException('${error.message}; it was not converted.')
        : ImageConversionException(error.message);
  }
}

/// Whether the decoder's own reading ([info] from its `startDecode`) is of
/// an animated PNG or WebP, which are not converted in this version. An
/// animated GIF is still converted; [_convertsAnimatedGif] turns that off.
bool _isAnimated(img.DecodeInfo info) => switch (info) {
  // A plain PNG reads as one frame (numFrames defaults to 1) without fcTL.
  img.PngInfo() => info.numFrames > 1 || info.frames.isNotEmpty,
  img.WebPInfo() =>
    info.hasAnimation ||
        info.frames.isNotEmpty ||
        info.format == img.WebPFormat.animated,
  img.GifInfo() => !_convertsAnimatedGif && info.numFrames > 1,
  _ => false,
};

/// Whether an animated GIF is converted: its decoder checks every frame
/// against its logical screen while decoding.
const bool _convertsAnimatedGif = true;

/// For a JPEG, refuses a frame (`SOFn`) whose number of components is not
/// 1 or 3 (the ones converted), before anything is decoded. An early
/// refusal for ordinary files, not a guarantee: the guarantee is the pixel
/// limit the decoder is held to. Segments are walked by their lengths, and
/// entropy-coded data byte by byte to its next marker. Not a JPEG: nothing
/// to do.
void _checkJpegComponents(Uint8List bytes) {
  final n = bytes.length;
  if (n < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return;
  }
  var at = 2;
  while (at + 4 <= n) {
    if (bytes[at] != 0xFF) {
      // Entropy-coded data: on to the next marker (not a stuffed 0xFF00
      // or a restart marker).
      at++;
      continue;
    }
    final marker = bytes[at + 1];
    if (marker == 0xFF ||
        marker == 0x00 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      at += marker == 0xFF ? 1 : 2;
      continue;
    }
    if (marker == 0xD9) {
      return;
    }
    final length = (bytes[at + 2] << 8) | bytes[at + 3];
    final sof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (sof) {
      final components = at + 9 < n ? bytes[at + 9] : 0;
      if (components != 1 && components != 3) {
        throw ImageConversionException(
          'The JPEG has $components color components; only 1 or 3 are '
          'converted.',
        );
      }
    }
    at += 2 + length;
  }
}
