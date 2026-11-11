import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/image_size.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List<int> be32(int v) => [
  v >> 24 & 0xff,
  v >> 16 & 0xff,
  v >> 8 & 0xff,
  v & 0xff,
];
List<int> le32(int v) => [
  v & 0xff,
  v >> 8 & 0xff,
  v >> 16 & 0xff,
  v >> 24 & 0xff,
];
List<int> le16(int v) => [v & 0xff, v >> 8 & 0xff];
List<int> be16(int v) => [v >> 8 & 0xff, v & 0xff];

Uint8List png(int w, int h) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...be32(13), ...'IHDR'.codeUnits, ...be32(w), ...be32(h), 8, 2, 0, 0, 0,
]);

Uint8List gif(int w, int h) => Uint8List.fromList([
  ...'GIF89a'.codeUnits,
  ...le16(w),
  ...le16(h),
  0,
  0,
  0,
]);

/// A JPEG with an APP1 segment of [app1] bytes before its frame.
Uint8List jpeg(int w, int h, {int app1 = 16}) => Uint8List.fromList([
  0xFF, 0xD8, //
  0xFF, 0xE1, ...be16(app1 + 2), ...List.filled(app1, 0x41),
  0xFF, 0xFF, // fill bytes before the marker
  0xC0, ...be16(17), 8, ...be16(h), ...be16(w), 3, ...List.filled(9, 0),
  0xFF, 0xDA, 0, 2,
]);

Uint8List webpLossy(int w, int h) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  ...le32(30),
  ...'WEBP'.codeUnits,
  ...'VP8 '.codeUnits,
  ...le32(18),
  0,
  0,
  0,
  0x9D,
  0x01,
  0x2A,
  ...le16(w),
  ...le16(h),
  0,
  0,
]);

Uint8List webpLossless(int w, int h) {
  final a = w - 1, b = h - 1;
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ...le32(30),
    ...'WEBP'.codeUnits,
    ...'VP8L'.codeUnits,
    ...le32(10),
    0x2F,
    a & 0xff,
    (a >> 8 & 0x3F) | (b & 0x3) << 6,
    b >> 2 & 0xff,
    b >> 10 & 0xF,
    0,
    0,
    0,
    0,
    0,
  ]);
}

Uint8List webpExtended(int w, int h) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  ...le32(30),
  ...'WEBP'.codeUnits,
  ...'VP8X'.codeUnits,
  ...le32(10),
  0,
  0,
  0,
  0,
  ...le32(w - 1).sublist(0, 3),
  ...le32(h - 1).sublist(0, 3),
]);

Uint8List bmp(int w, int h, {bool topDown = false}) => Uint8List.fromList([
  ...'BM'.codeUnits, ...le32(54), 0, 0, 0, 0, ...le32(54), //
  ...le32(40), ...le32(w), ...le32(topDown ? -h : h), 1, 0, 24, 0,
]);

UploadedFile upload(List<int> bytes, [String name = 'a.bin']) =>
    UploadedFile.fromBytes(bytes, name: name);

void main() {
  phpGolden();

  group('header sizes, as getimagesize', () {
    test('every format', () {
      expect(imageSize(png(640, 480)), (width: 640, height: 480));
      expect(imageSize(gif(32, 16)), (width: 32, height: 16));
      expect(imageSize(jpeg(1024, 768)), (width: 1024, height: 768));
      expect(imageSize(webpLossy(300, 200)), (width: 300, height: 200));
      expect(imageSize(webpLossless(300, 200)), (width: 300, height: 200));
      expect(imageSize(webpExtended(5000, 4000)), (width: 5000, height: 4000));
      expect(imageSize(bmp(10, 20)), (width: 10, height: 20));
      expect(imageSize(bmp(10, 20, topDown: true)), (width: 10, height: 20));
    });

    test('a cut header, a zero size or not an image: no size', () {
      for (final whole in [
        png(1, 1),
        gif(1, 1),
        jpeg(1, 1),
        webpLossy(1, 1),
        bmp(1, 1),
      ]) {
        for (var n = 0; n < whole.length - 1; n++) {
          final cut = Uint8List.sublistView(whole, 0, n);
          // A JPEG cut after its frame header still has a size.
          final size = imageSize(cut);
          expect(size == null || size == (width: 1, height: 1), isTrue);
        }
      }
      // A declared zero is reported as PHP reports it.
      expect(imageSize(png(0, 10)), (width: 0, height: 10));
      expect(imageSize(gif(10, 0)), (width: 10, height: 0));
      expect(imageSize(Uint8List.fromList('<html>'.codeUnits)), isNull);
      // A JPEG whose scan comes before any frame.
      expect(
        imageSize(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])),
        isNull,
      );
    });

    test('random and mutated bytes never throw', () {
      final random = Random(7);
      final samples = [
        png(9, 9),
        gif(9, 9),
        jpeg(9, 9),
        webpLossy(9, 9),
        webpLossless(9, 9),
        webpExtended(9, 9),
        bmp(9, 9),
      ];
      for (var i = 0; i < 20000; i++) {
        final base = samples[i % samples.length];
        final bytes = Uint8List.fromList(
          i.isEven
              ? base
              : [
                  for (var j = random.nextInt(64); j > 0; j--)
                    random.nextInt(256),
                ],
        );
        for (
          var flips = random.nextInt(4);
          flips > 0 && bytes.isNotEmpty;
          flips--
        ) {
          bytes[random.nextInt(bytes.length)] = random.nextInt(256);
        }
        final cut = Uint8List.sublistView(
          bytes,
          0,
          random.nextInt(bytes.length + 1),
        );
        expect(() => imageSize(cut), returnsNormally);
      }
    });

    test('a JPEG segment length that lies: no size, no overrun', () {
      final lying = jpeg(10, 10);
      lying[4] = 0xFF; // APP1 length 0xFF12: past the end
      expect(imageSize(lying), isNull);
    });

    test('only the first bytes of an upload are read', () async {
      final dir = Directory.systemTemp.createTempSync('dimensions_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final big = File(p.join(dir.path, 'big.jpg'))
        ..writeAsBytesSync([
          ...jpeg(64, 48),
          ...List.filled(3 * maxImageHeaderBytes, 0),
        ]);
      final file = UploadedFile.temporary(
        path: big.path,
        clientName: 'big.jpg',
        clientMimeType: 'image/jpeg',
        size: big.lengthSync(),
        header: jpeg(64, 48),
      );
      final head = await imageHeaderOf(file);
      expect(head.length, maxImageHeaderBytes);
      expect(imageSize(head), (width: 64, height: 48));
      // Five 64 KiB APP segments (more than the limit) before the frame:
      // the frame is never read, so there is no size.
      final app = [
        0xFF,
        0xE1,
        ...be16(0xFFF0 + 2),
        ...List.filled(0xFFF0, 0x41),
      ];
      final frame = jpeg(64, 48).sublist(2);
      final deep = upload([
        0xFF,
        0xD8,
        for (var i = 0; i < 5; i++) ...app,
        ...frame,
      ]);
      expect(imageSize(await deep.bytes()), (width: 64, height: 48));
      expect(imageSize(await imageHeaderOf(deep)), isNull);
    });
  });

  group('the rule', () {
    Future<bool> valid(Object? value, Object rule) async =>
        (await Validator({'photo': value}, {'photo': rule}).run()).isEmpty;

    final photo = upload(png(300, 200), 'photo.png');

    test('the DSL constraints, as Laravel', () async {
      expect(await valid(photo, 'dimensions:width=300,height=200'), isTrue);
      expect(await valid(photo, 'dimensions:min_width=301'), isFalse);
      expect(await valid(photo, 'dimensions:max_width=299'), isFalse);
      expect(
        await valid(photo, 'dimensions:min_height=200,max_height=200'),
        isTrue,
      );
      expect(await valid(photo, 'dimensions:ratio=3/2'), isTrue);
      expect(await valid(photo, 'dimensions:ratio=1.5'), isTrue);
      expect(await valid(photo, 'dimensions:ratio=1/1'), isFalse);
      expect(
        await valid(photo, 'dimensions:min_ratio=1/1,max_ratio=2/1'),
        isTrue,
      );
      expect(await valid(photo, 'dimensions:min_ratio=2/1'), isFalse);
      expect(await valid(photo, 'dimensions:max_ratio=1/1'), isFalse);
    });

    test('the builder takes the same constraints', () async {
      expect(
        await valid(photo, Rules.dimensions(minWidth: 100, ratio: '3/2')),
        isTrue,
      );
      expect(
        await valid(photo, Rules.file().dimensions(maxHeight: 100)),
        isFalse,
      );
    });

    test('ratios are read as PHP sscanf and array_filter do', () {
      expect(DimensionsRule.phpRatio('3/2'), 1.5);
      expect(DimensionsRule.phpRatio('1.5'), 1.5);
      expect(DimensionsRule.phpRatio('0/2'), 0.5); // 0 dropped: 1/2
      expect(DimensionsRule.phpRatio('3/0'), 3.0); // 0 dropped: 3/1
      expect(DimensionsRule.phpRatio('x'), 1.0);
      expect(DimensionsRule.phpRatio(' 16/9'), closeTo(16 / 9, 1e-12));
    });

    test('an SVG passes; not an image or not a file fails', () async {
      final svg = upload(
        '<svg xmlns="http://www.w3.org/2000/svg"/>'.codeUnits,
        'a.svg',
      );
      expect(await valid(svg, 'dimensions:min_width=1000'), isTrue);
      expect(
        await valid(upload('hello'.codeUnits), 'dimensions:min_width=1'),
        isFalse,
      );
      expect(await valid('photo.png', 'dimensions:min_width=1'), isFalse);
    });

    test('a constraint that is not a number fails', () async {
      expect(await valid(photo, 'dimensions:min_width=abc'), isFalse);
    });

    test('a declared zero size: limits apply, a ratio fails', () async {
      // PHP reports [0, 10] and Laravel checks the limits with it; a ratio
      // over height 0 throws in Laravel and fails here.
      final flat = upload(png(10, 0), 'flat.png');
      expect(
        await valid(upload(png(0, 10)), 'dimensions:max_width=100'),
        isTrue,
      );
      expect(await valid(flat, 'dimensions:max_height=5'), isTrue);
      expect(await valid(flat, 'dimensions:ratio=3/2'), isFalse);
      expect(await valid(flat, 'dimensions:min_ratio=1/1'), isFalse);
    });

    test('no constraint at all is an error, as Laravel', () {
      expect(valid(photo, 'dimensions'), throwsArgumentError);
    });

    test("the message is Laravel's", () async {
      final errors = await Validator(
        {'photo': photo},
        {'photo': 'dimensions:min_width=1000'},
      ).run();
      expect(errors['photo'], [
        'The photo field has invalid image dimensions.',
      ]);
    });
  });
}

/// The headers above (whole, cut, zero, not an image) were run through
/// PHP 8.2's `getimagesize` in the `daravel-interop-laravel-12` image of
/// `bench/interop` (`docker run --rm --network=none ... php`).
void phpGolden() {
  test('imageSize agrees with PHP getimagesize on every case', () {
    final fixture = jsonDecode(
      File('test/validation/fixtures/php_getimagesize.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final cases = (fixture['cases']! as Map<String, Object?>)
        .cast<String, Map<String, Object?>>();
    expect(cases, hasLength(greaterThan(10)));
    final disagreements = <String>[];
    for (final MapEntry(key: name, value: c) in cases.entries) {
      final size = imageSize(base64.decode(c['bytes']! as String));
      final php = (c['size'] as List<Object?>?)?.cast<int>();
      final ours = size == null ? null : [size.width, size.height];
      if (php?.join('x') != ours?.join('x')) {
        disagreements.add('$name: PHP $php, Daravel $ours');
      }
    }
    expect(disagreements, isEmpty);
  });
}
