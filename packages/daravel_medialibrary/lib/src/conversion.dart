// Follows spatie/laravel-medialibrary and spatie/image, Copyright (c)
// Spatie bvba, MIT License: see THIRD_PARTY_NOTICES.md.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'config.dart';
import 'image_guard.dart';
import 'conversion_plan.dart';
import 'jpeg_walk.dart';

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

/// The image library threw an [Error] reading, decoding or encoding this
/// file (a defect of it, met on this file): the file is not converted, and
/// its conversion job fails at once instead of trying again.
final class ImageLibraryException extends ImageConversionException {
  /// The library threw [errorType] with [detail].
  const ImageLibraryException(this.errorType, String detail)
    : super('The image library failed ($errorType): $detail');

  /// The type of what the library threw, as `RangeError`.
  final String errorType;
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
/// converted in this version. An image with a side longer than 65 535, or
/// a JPEG with more scans than its size allows, is not converted. A
/// manipulation does not make an image of more than a quarter of
/// [maxPixels], frames counted, nor one with a side longer than 65 535:
/// past that, [ImageTooLargeException]. Blur is limited separately by its
/// pixels, frames and radius. Put a resize before blur to reduce its cost;
/// manipulations still run in the order the conversion defines.
///
/// The limit bounds an image's size, not memory exactly: at the default
/// limit, plan about 500 MiB of memory per conversion running at once,
/// whatever the size of the image. Measured peaks (a compiled process):
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
/// | WebP, 4 472 x 4 472, worst measured | about 395 MiB (470 with orientation) | 2.6 s |
/// | GIF, 1 000 frames of 200 x 200 | about 140 MiB | 1.2 s |
/// | GIF, 2 frames of 4 472 x 4 472 | about 110 MiB | 1 s |
/// | JPEG at its scan limit (40, 20 or 5 MP) | up to about 430 MiB at 40 MP | up to 9.1 s |
/// | a manipulation making 10 million pixels | about 47 to 76 MiB | 4.5 to 5.2 s (6.3 to 7.2 s on a slower reference machine) |
/// | still blur at its budget (8 or 16 bits, 1, 3 or 4 channels) | up to about 130 MiB (40 MP, radius 2) | 2.1 to 4.0 s |
/// | animated blur at its 20-million pixel-frame-radius budget | about 125 MiB for a GIF | 3.2 s (4.4 s on a slower reference machine) |
/// | encoding an unchanged 40-million-pixel photograph as JPEG or PNG | about 132 to 140 MiB | 3.4 to 4.9 s (up to 6.7 s on a slower reference machine) |
/// | a GIF written at its limit (4 million pixels of a photograph) | about 100 MiB | about 4.7 s to encode |
/// | a crop or resize of a 1, 2 or 4-bit image | small | up to about 4 s at 40 MP (crop) |
/// | a whole conversion at the limits, slowest measured: a 16-bit PNG of 20 MP resized, blurred, written as PNG (a 40 MP JPEG blurred, written as PNG: 16 s) | up to about 384 MiB | up to about 19 s (26 s on a slower reference machine) |
Future<Uint8List> convertImage(
  Uint8List bytes,
  Map<String, List<Object?>> manipulations, {
  int maxPixels = MediaLibraryConfig.defaultMaxImagePixels,
  int maxFrames = MediaLibraryConfig.defaultMaxImageFrames,
  int maxWork = MediaLibraryConfig.defaultMaxConversionWork,
}) => Isolate.run(
  () => convertImageSync(
    bytes,
    manipulations,
    maxPixels: maxPixels,
    maxFrames: maxFrames,
    maxWork: maxWork,
  ),
);

/// [convertImage] on the calling isolate.
///
/// The whole conversion (decoding, every manipulation, writing) is
/// estimated in work units before it runs, from the image's size, frames
/// and pixel format, and refused past [maxWork]
/// (`MEDIA_MAX_CONVERSION_WORK`).
Uint8List convertImageSync(
  Uint8List bytes,
  Map<String, List<Object?>> manipulations, {
  int maxPixels = MediaLibraryConfig.defaultMaxImagePixels,
  int maxFrames = MediaLibraryConfig.defaultMaxImageFrames,
  int maxWork = MediaLibraryConfig.defaultMaxConversionWork,
}) {
  if (maxPixels < 1 || maxFrames < 1 || maxWork < 1) {
    throw ArgumentError('maxPixels, maxFrames and maxWork are at least 1.');
  }
  // One decoder instance reads the file once: what is checked below is
  // the decoder's own reading, and the same instance then decodes it.
  final decoder = _decoderFor(bytes, maxPixels);
  if (decoder is img.JpegDecoder) {
    _checkJpegComponents(bytes);
  }
  final info = decoder == null
      ? null
      : guardImageCall(() => decoder.startDecode(bytes));
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
  // A very long side costs time even with few pixels, and no JPEG or GIF
  // (the formats written) can hold more than [_maxImageSide].
  if (info.width > _maxImageSide || info.height > _maxImageSide) {
    throw ImageTooLargeException(
      'The image is ${info.width} x ${info.height} pixels, a side longer '
      'than $_maxImageSide; it was not converted.',
    );
  }
  if (decoder is img.JpegDecoder) {
    _checkJpegFrames(bytes, info.width, info.height, maxPixels);
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
  final container = _containerOf(info, decoder);
  final kind = _kindOfInfo(info, decoder, bytes);
  if (container == null || kind == null) {
    throw ImageConversionException(
      'The image\'s pixels (${_describeInfo(info)}) are not converted in '
      'this version.',
    );
  }
  final growth = math.max(1, maxPixels ~/ _growthDivisor);
  // Before decoding: refused when the conversion of the header's image is
  // refused either way it may be turned (its EXIF orientation is read
  // with the pixels).
  final upright = (
    width: info.width,
    height: info.height,
    frames: frames,
    kind: kind,
  );
  final turned = (
    width: info.height,
    height: info.width,
    frames: frames,
    kind: kind,
  );
  Object? refusal;
  for (final shape in [upright, turned]) {
    try {
      _plannedWithin(container, shape, manipulations, growth, maxWork);
      refusal = null;
      break;
    } on ImageConversionException catch (error) {
      refusal ??= error;
    }
  }
  if (refusal != null) {
    throw refusal;
  }
  // A still image: its one frame, from the reading checked above. An
  // animated GIF is decoded whole, each frame held to the limits above.
  final decoded = guardImageCall(
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
      : guardImageCall(() => img.bakeOrientation(decoded));
  // The steps of the image as decoded, turned upright: what runs.
  final decodedKind = kindOfImage(image);
  if (decodedKind == null) {
    throw ImageConversionException(
      'The image\'s pixels (${image.format.name}, ${image.numChannels} '
      'channels) are not converted in this version.',
    );
  }
  final steps = _plannedWithin(
    container,
    (
      width: image.width,
      height: image.height,
      frames: math.max(1, image.numFrames),
      kind: decodedKind,
    ),
    manipulations,
    growth,
    maxWork,
  );
  for (final step in steps) {
    switch (step) {
      case ToEightBit():
        final current = image;
        image = guardImageCall(
          () => current.convert(
            format: img.Format.uint8,
            numChannels: step.shape.kind.channels,
          ),
        );
      case Resize(:final shape):
        final current = image;
        image = guardImageCall(
          () => img.copyResize(
            current,
            width: shape.width,
            height: shape.height,
            interpolation: img.Interpolation.cubic,
          ),
        );
      case Crop(:final shape, :final x, :final y):
        image = _cropped(image, x, y, shape.width, shape.height);
      case Canvas(:final shape, :final source):
        image = _onCanvas(image, shape, source);
      case Greyscale():
        final current = image;
        image = guardImageCall(() => img.grayscale(current));
      case Blur(:final radius):
        final current = image;
        image = guardImageCall(() => img.gaussianBlur(current, radius: radius));
      case Encode(:final format, :final quality):
        final current = image;
        return guardImageCall(
          () => switch (format) {
            ImageFormat.png => img.encodePng(current),
            ImageFormat.gif => img.encodeGif(current),
            ImageFormat.bmp => img.encodeBmp(current),
            ImageFormat.tiff => img.encodeTiff(current),
            // GD's default JPEG quality when none is set.
            ImageFormat.jpg => img.encodeJpg(current, quality: quality ?? 75),
          },
        );
    }
  }
  throw StateError('A conversion plan ends with its encoding.');
}

/// The steps of a conversion of an image of [shape] from [container],
/// refused when they are ([planConversion]), when a step has no measured
/// cost for its pixels, or when their work is past [maxWork].
List<ConversionStep> _plannedWithin(
  ImageContainer container,
  ImageShape shape,
  Map<String, List<Object?>> manipulations,
  int growth,
  int maxWork,
) {
  final steps = planConversion(
    shape,
    manipulations,
    growth: growth,
    maxSide: _maxImageSide,
  );
  final work = conversionCost(container, shape, steps, orient: true);
  if (work == null) {
    throw const ImageConversionException(
      'A step of this conversion is not run on the image\'s pixels in this '
      'version.',
    );
  }
  if (work > maxWork) {
    throw ImageTooLargeException(
      'The conversion of a ${shape.width} x ${shape.height} image'
      '${shape.frames > 1 ? ' of ${shape.frames} frames' : ''} would take '
      'about ${work.round()} work units, past MEDIA_MAX_CONVERSION_WORK '
      '($maxWork); it was not converted.',
    );
  }
  return steps;
}

/// [image] cut to [width] x [height] at [x], [y], every frame keeping its
/// duration.
img.Image _cropped(img.Image image, int x, int y, int width, int height) {
  final cut = guardImageCall(
    () => img.copyCrop(image, x: x, y: y, width: width, height: height),
  );
  for (var i = 0; i < cut.numFrames && i < image.numFrames; i++) {
    cut.frames[i].frameDuration = image.frames[i].frameDuration;
  }
  return cut;
}

/// spatie/image's `resizeCanvas()` centered: every frame of [image] (of
/// [source]'s size) on a white canvas of [shape], with its duration.
img.Image _onCanvas(img.Image image, ImageShape shape, ImageShape source) {
  img.Image? canvas;
  final channels = shape.kind.channels;
  final dstX = (shape.width - source.width) ~/ 2;
  final dstY = (shape.height - source.height) ~/ 2;
  for (var i = 0; i < image.numFrames; i++) {
    final frame = image.frames[i];
    final page = guardImageCall(() {
      final page = img.Image(
        width: shape.width,
        height: shape.height,
        numChannels: channels,
      );
      img.fill(page, color: img.ColorRgba8(255, 255, 255, 255));
      return img.compositeImage(page, frame, dstX: dstX, dstY: dstY);
    });
    page.frameDuration = frame.frameDuration;
    if (canvas == null) {
      canvas = page
        ..loopCount = image.loopCount
        ..frameType = image.frameType;
    } else {
      final frames = canvas;
      guardImageCall(() => frames.addFrame(page));
    }
  }
  return canvas!;
}

/// How the file was stored, as far as decoding costs differ; null for a
/// container without measured costs, which is refused (none reaches here
/// today: only these five decoders are tried).
ImageContainer? _containerOf(img.DecodeInfo info, img.Decoder decoder) =>
    switch ((info, decoder)) {
      (img.JpegInfo(), img.JpegDecoder()) => ImageContainer.jpeg,
      (img.PngInfo(), img.PngDecoder()) => ImageContainer.png,
      (img.GifInfo(), img.GifDecoder()) => ImageContainer.gif,
      (img.WebPInfo(:final format), img.WebPDecoder()) =>
        switch (format) {
          img.WebPFormat.lossless => ImageContainer.webpLossless,
          img.WebPFormat.lossy => ImageContainer.webpLossy,
          _ => null,
        },
      (_, img.BmpDecoder()) => ImageContainer.bmp,
      _ => null,
    };

/// A BMP's bits per pixel, from its header (the 16-bit field at byte 28).
int _bmpBitsPerPixel(Uint8List bytes) =>
    bytes.length < 30 ? 0 : bytes[28] | (bytes[29] << 8);

/// The pixels the header announces, or null for a kind without measured
/// costs (it is refused).
PixelKind? _kindOfInfo(
  img.DecodeInfo info,
  img.Decoder decoder,
  Uint8List bytes,
) {
  if (decoder is img.BmpDecoder) {
    return switch (_bmpBitsPerPixel(bytes)) {
      1 || 2 || 4 => PixelKind.lowBit,
      8 => PixelKind.palette8,
      24 => PixelKind.rgb8,
      32 => PixelKind.rgba8,
      _ => null,
    };
  }
  return switch (info) {
    img.JpegInfo() => PixelKind.rgb8,
    img.GifInfo() => PixelKind.palette8,
    img.WebPInfo() => PixelKind.rgba8,
    img.PngInfo(:final bits, :final colorType, :final transparency) => switch ((
      colorType,
      bits,
    )) {
      (0, 1 || 2 || 4) => PixelKind.lowBitGray,
      (0, 8) => PixelKind.gray8,
      (0, 16) => PixelKind.gray16,
      (2, 8) => PixelKind.rgb8,
      (2, 16) => PixelKind.rgb16,
      (3, 1 || 2 || 4) =>
        transparency == null ? PixelKind.lowBit : PixelKind.lowBitAlpha,
      (3, 8) =>
        transparency == null ? PixelKind.palette8 : PixelKind.paletteAlpha8,
      (4, 8) => PixelKind.grayAlpha8,
      (4, 16) => PixelKind.grayAlpha16,
      (6, 8) => PixelKind.rgba8,
      (6, 16) => PixelKind.rgba16,
      _ => null,
    },
    _ => null,
  };
}

String _describeInfo(img.DecodeInfo info) => switch (info) {
  img.PngInfo(:final bits, :final colorType) =>
    'PNG color type $colorType, $bits bits',
  _ => info.runtimeType.toString(),
};

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

/// Whether an animated GIF is converted (each frame within the limits).
const bool _convertsAnimatedGif = true;

/// The longest side converted, of the image read and of any image a
/// manipulation makes: the most a JPEG or a GIF (the formats written) can
/// hold. A long side costs time even with few pixels (decoding and
/// writing go row by row): measured, a 1 x 1 000 000 PNG took 0.5 s and
/// 40 000 000 rows about 20 s; at 65 535, 64 ms or less in every format.
const int _maxImageSide = 65535;

/// A manipulation may make an image of up to
/// `maxPixels ~/ _growthDivisor` (frames counted): 10 million pixels at the
/// default limit, whether it grows or shrinks the input. The quarter keeps a
/// usual 1080p to 4K enlargement possible. Measured with cubic interpolation
/// and JPEG or PNG output, one step at the boundary took 4.5 to 5.2 s on the
/// current machine and 6.3 to 7.2 s on a slower reference machine. Every
/// manipulation is checked separately: several resize steps pay that cost
/// several times.
const int _growthDivisor = 4;

/// For a JPEG, refuses one with more scans than its size allows, before
/// it is decoded. Each scan is a pass over the frame, so a small file of
/// many scans takes a long time to decode.
///
/// - The segments before the first scan are walked by their markers and
///   lengths ([jpegSegments]), so what APPn and COM carry (an EXIF
///   thumbnail included) is passed over. From the first `FF DA` (start of
///   scan) on, every `FF DA` in the bytes counts: an upper bound on the
///   scans in the file.
/// - Anything before the first scan that is not a plain segment of a
///   baseline, extended or progressive JPEG (an unknown marker, another
///   frame type, a length below 2, no start of image) makes every `FF DA`
///   of the whole file count, from its first byte: counting more can only
///   refuse.
/// - The frame is the largest of [width] x [height] (read from the file's
///   header) and of every frame header candidate the walk reads or the
///   counting passes: each `FF Cn` ([isJpegFrame]) whose 16-bit height
///   and width, at their fixed place after it, are at least 1 with a
///   product of at most [maxPixels]. Decoding is held to [maxPixels], so a
///   larger frame is refused when it is read. A candidate in other data
///   (camera maker notes hold some) only tightens the budget, and since no
///   candidate passes [maxPixels], a file of 16 `FF DA` or fewer is never
///   refused by one.
/// - At most `16 x maxPixels` scanned pixels, counted in whole 8 x 8 blocks
///   of that frame: 16 scans for 40 MP, 64 for 10 MP. Measured, the worst
///   file at the limit took about 3.4 s whatever its size; real
///   progressive JPEGs (5 to 12 `FF DA`) stayed under a third of it.
void _checkJpegFrames(Uint8List bytes, int width, int height, int maxPixels) {
  final (scans, frameWidth, frameHeight) = jpegScanBound(
    bytes,
    width,
    height,
    maxPixels,
  );
  if (scans == 0) {
    return;
  }
  final blockWidth = (frameWidth + 7) ~/ 8 * 8;
  final blockHeight = math.max(8, (frameHeight + 7) ~/ 8 * 8);
  // 16 x maxPixels without overflowing for any configured limit.
  final budget = maxPixels > (1 << 58) ? (1 << 62) : maxPixels * 16;
  if (blockWidth > budget ~/ scans ~/ blockHeight) {
    throw ImageTooLargeException(
      'The JPEG holds up to $scans scans of $frameWidth x $frameHeight '
      'pixels, more than its size allows; it was not converted.',
    );
  }
}

/// For a JPEG, refuses a frame (`SOFn`) whose number of components is not
/// 1 or 3 (the ones converted), before anything is decoded. An early
/// refusal for ordinary files, not a guarantee: the guarantee is the pixel
/// limit decoding is held to. The segments are those of the walk
/// ([jpegSegments]), the same walk as [_checkJpegFrames]. Not a JPEG:
/// nothing to do.
void _checkJpegComponents(Uint8List bytes) {
  final start = jpegMarker(bytes, 0);
  if (start == null || start.marker != 0xD8) {
    return;
  }
  final n = bytes.length;
  for (final (:marker, :at, next: _, length: _) in jpegSegments(
    bytes,
    start.after,
  )) {
    if (isJpegFrame(marker)) {
      // The count of components, 8 bytes after the marker.
      final components = at + 8 < n ? bytes[at + 8] : 0;
      if (components != 1 && components != 3) {
        throw ImageConversionException(
          'The JPEG has $components color components; only 1 or 3 are '
          'converted.',
        );
      }
    }
  }
}
