import 'dart:math';
import 'dart:typed_data';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// After every step a conversion runs, the image has the size, frames and
/// pixel kind its plan priced; otherwise it is refused before the next
/// step. Every input the conversion accepts (container x pixel kind) with
/// every single step, ordered pairs of steps, and every output format, on
/// small images: no plan the model accepts meets that check.
void main() {
  final random = Random(7);

  img.Image fill(img.Image image) {
    for (final frame in image.frames) {
      for (final p in frame) {
        if (frame.hasPalette) {
          p.index = random.nextInt(frame.palette!.numColors);
        } else {
          final max = p.maxChannelValue.toInt() + 1;
          p
            ..r = random.nextInt(max)
            ..g = random.nextInt(max)
            ..b = random.nextInt(max)
            ..a = random.nextInt(max);
        }
      }
    }
    return image;
  }

  img.Image plain(int channels, img.Format format) => fill(
    img.Image(width: 8, height: 6, numChannels: channels, format: format),
  );

  img.Image palette(img.Format format, {int channels = 3}) => fill(
    img.Image(
      width: 8,
      height: 6,
      format: format,
      withPalette: true,
      numPaletteColors: format == img.Format.uint8 ? 256 : 16,
      paletteFormat: img.Format.uint8,
      numChannels: channels,
    ),
  );

  img.Image animated(int frames) {
    final first = palette(img.Format.uint8);
    for (var i = 1; i < frames; i++) {
      first.addFrame(palette(img.Format.uint8));
    }
    return first;
  }

  final inputs = <String, Uint8List>{
    'png gray8': img.encodePng(plain(1, img.Format.uint8)),
    'png grayAlpha8': img.encodePng(plain(2, img.Format.uint8)),
    'png rgb8': img.encodePng(plain(3, img.Format.uint8)),
    'png rgba8': img.encodePng(plain(4, img.Format.uint8)),
    'png gray16': img.encodePng(plain(1, img.Format.uint16)),
    'png grayAlpha16': img.encodePng(plain(2, img.Format.uint16)),
    'png rgb16': img.encodePng(plain(3, img.Format.uint16)),
    'png rgba16': img.encodePng(plain(4, img.Format.uint16)),
    'png palette8': img.encodePng(palette(img.Format.uint8)),
    'png paletteAlpha8': img.encodePng(palette(img.Format.uint8, channels: 4)),
    'png lowBit': img.encodePng(palette(img.Format.uint4)),
    'png lowBitGray': img.encodePng(plain(1, img.Format.uint1)),
    'jpeg rgb8': img.encodeJpg(plain(3, img.Format.uint8)),
    'jpeg gray8': img.encodeJpg(plain(1, img.Format.uint8)),
    'gif palette8': img.encodeGif(animated(1)),
    'gif palette8 x3': img.encodeGif(animated(3)),
    'bmp rgb8': img.encodeBmp(plain(3, img.Format.uint8)),
    'bmp rgba8': img.encodeBmp(plain(4, img.Format.uint8)),
    'bmp palette8': img.encodeBmp(palette(img.Format.uint8)),
    'bmp lowBit': img.encodeBmp(palette(img.Format.uint4)),
  };

  final singles = <String, MapEntry<String, List<Object?>>>{
    'width down': const MapEntry('width', [5]),
    'width up': const MapEntry('width', [12]),
    'height': const MapEntry('height', [4]),
    for (final fit in Fit.values)
      'fit ${fit.name}': MapEntry('fit', [fit.name, 7, 5]),
    'crop': const MapEntry('crop', [4, 3, 'center']),
    'greyscale': const MapEntry('greyscale', <Object?>[]),
    'blur': const MapEntry('blur', [4]),
  };
  const paired = ['width up', 'fit fill', 'crop', 'greyscale', 'blur'];

  test('no step makes an image other than its plan says', () {
    final mismatches = <String, String>{};
    var converted = 0;
    var refused = 0;
    final chains = <String, Map<String, List<Object?>>>{
      for (final MapEntry(key: name, value: step) in singles.entries)
        name: {step.key: step.value},
      for (final a in paired)
        for (final b in paired)
          if (a != b && singles[a]!.key != singles[b]!.key)
            '$a, $b': {
              singles[a]!.key: singles[a]!.value,
              singles[b]!.key: singles[b]!.value,
            },
    };
    for (final MapEntry(key: input, value: bytes) in inputs.entries) {
      for (final MapEntry(key: name, value: chain) in chains.entries) {
        for (final format in ['jpg', 'png', 'gif', 'bmp', 'tiff']) {
          try {
            convertImageSync(bytes, {
              ...chain,
              'format': [format],
            }, maxWork: 1 << 40);
            converted++;
          } on ImageConversionException catch (e) {
            if (e.message.contains('its plan says')) {
              mismatches['$input | $name | $format'] = e.message;
            } else {
              refused++;
            }
          }
        }
      }
    }
    print('converted $converted, refused otherwise $refused');
    expect(mismatches, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
