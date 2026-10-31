import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel_teobiefy/src/zstd_decoder.dart';
import 'package:test/test.dart';

/// Frames written by PHP's `zstd_compress()` (ext-zstd 0.18, libzstd 1.5.7)
/// and the `zstd` command line, in `test/fixtures/zstd`.
void main() {
  const directory = 'test/fixtures/zstd';
  const limit = 10 * 1024 * 1024;

  Uint8List read(String name) => File('$directory/$name').readAsBytesSync();

  group('real frames', () {
    for (final (name, plain, why) in const [
      ('small.zst', 'small.plain', 'a short JSON object'),
      ('medium.zst', 'medium.plain', 'four Huffman streams, custom FSE tables'),
      ('big-1.zst', 'big.plain', 'many blocks, level 1'),
      ('big-3.zst', 'big.plain', 'many blocks, level 3'),
      ('big-9.zst', 'big.plain', 'treeless literals, repeat mode'),
      ('big-19.zst', 'big.plain', 'long matches, level 19'),
      ('tiny-1.zst', 'tiny-1.plain', 'two bytes'),
      ('runs.zst', 'runs.plain', 'one byte, repeated: overlapping matches'),
      ('checksum.zst', 'checksum.plain', 'a content checksum'),
      ('nosize.zst', 'nosize.plain', 'no content size'),
    ]) {
      test('$name: $why', () {
        expect(zstdDecompress(read(name), maxOutput: limit), read(plain));
      });
    }

    test('the big frames span more than one block', () {
      expect(read('big.plain').length, greaterThan(128 * 1024));
    });
  });

  test('RLE_Mode, then Repeat_Mode on all three sequence tables', () {
    final frame = Uint8List.fromList([
      0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x10, //
      0x44, 0x00, 0x00, 0x08, 0x61, 0x01, 0x54, 0x01, 0x02, 0x04, 0x04,
      0x2D, 0x00, 0x00, 0x08, 0x62, 0x01, 0xFC, 0x04,
    ]);
    expect(
      utf8.decode(zstdDecompress(frame, maxOutput: 64)),
      'aaaaaaaabbbbbbbb',
    );
  });

  group('xxh64', () {
    test('known values', () {
      expect(xxh64(Uint8List(0)), 0xEF46DB3751D8E999);
      expect(xxh64(Uint8List.fromList(utf8.encode('a'))), 0xD24EC4F1A98C6E5B);
    });
  });

  group('refused', () {
    test('not a frame', () {
      expect(
        () => zstdDecompress(Uint8List(8), maxOutput: limit),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('a cut frame', () {
      final frame = read('medium.zst');
      for (final length in [4, 5, 7, 100, frame.length - 1]) {
        expect(
          () => zstdDecompress(
            Uint8List.sublistView(frame, 0, length),
            maxOutput: limit,
          ),
          throwsA(isA<ZstdFormatException>()),
          reason: '$length',
        );
      }
    });

    test('a damaged checksum', () {
      final frame = Uint8List.fromList(read('checksum.zst'));
      frame[frame.length - 1] ^= 0xFF;
      expect(
        () => zstdDecompress(frame, maxOutput: limit),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('data after the frame', () {
      final frame = read('small.zst');
      expect(
        () =>
            zstdDecompress(Uint8List.fromList([...frame, 0]), maxOutput: limit),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('a dictionary', () {
      final frame = Uint8List.fromList(read('small.zst'));
      frame[4] |= 1;
      expect(
        () => zstdDecompress(frame, maxOutput: limit),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('a declared size over the limit, before any work', () {
      expect(
        () => zstdDecompress(read('runs.zst'), maxOutput: 1000),
        throwsA(isA<ZstdTooLargeException>()),
      );
    });

    test('a bomb that does not declare its size stops at the limit', () {
      final frame = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x48, //
        for (var i = 0; i < 40; i++) ...[
          for (final byte in [(i == 39 ? 1 : 0) | 2 | (100000 << 3)]) ...[
            byte & 255,
            (byte >> 8) & 255,
            (byte >> 16) & 255,
          ],
          0x41,
        ],
      ]);
      expect(
        () => zstdDecompress(frame, maxOutput: 1024 * 1024),
        throwsA(isA<ZstdTooLargeException>()),
      );
    });

    test('hostile bytes are refused, never a crash or a hang', () {
      final random = Random(7);
      for (final name in ['small.zst', 'medium.zst', 'big-3.zst']) {
        final original = read(name);
        for (var round = 0; round < 600; round++) {
          final frame = Uint8List.fromList(original);
          for (var flips = 0; flips <= round % 5; flips++) {
            frame[random.nextInt(frame.length)] = random.nextInt(256);
          }
          try {
            zstdDecompress(frame, maxOutput: 1024 * 1024);
          } on ZstdFormatException {
            // Refused.
          } on ZstdTooLargeException {
            // Refused.
          }
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
