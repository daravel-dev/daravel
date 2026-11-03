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

  test('more Huffman weights than symbols are refused', () {
    final frame = Uint8List.fromList([
      0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01, //
      0x55, 0x01, 0x00,
      0x12, 0x80, 0x09,
      0x24, 0x10, 0x3F, ...List<int>.filled(33, 0), 0x01,
      0x01, 0x00,
    ]);
    expect(
      () => zstdDecompress(frame, maxOutput: 64),
      throwsA(
        isA<ZstdFormatException>().having(
          (e) => e.message,
          'message',
          'Too many Huffman weights.',
        ),
      ),
    );
  });

  group('Huffman weight guards', () {
    /// A one-byte frame whose literals carry [weights] in the direct
    /// (4 bits each) Huffman description, then the one-byte [stream] and
    /// no sequences, so decoding reaches the checks on the weights at once.
    Uint8List directWeights(List<int> weights, {int stream = 0x04}) {
      final description = [
        127 + weights.length,
        for (var i = 0; i < weights.length; i += 2)
          (weights[i] << 4) | (i + 1 < weights.length ? weights[i + 1] : 0),
      ];
      // Compressed literals, one stream, 1 byte regenerated.
      final header = 2 | (1 << 4) | ((description.length + 1) << 14);
      final body = [
        header & 255,
        (header >> 8) & 255,
        header >> 16,
        ...description,
        stream,
        0x00, // no sequences
      ];
      final block = 1 | (2 << 1) | (body.length << 3);
      return Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01, //
        block & 255, (block >> 8) & 255, block >> 16,
        ...body,
      ]);
    }

    Matcher refusedWith(String message) => throwsA(
      isA<ZstdFormatException>().having((e) => e.message, 'message', message),
    );

    test('the same frame with legal weights decodes', () {
      // Weights 1, 1 and the implied 2: symbols 0 and 1 get 2-bit codes,
      // symbol 2 a 1-bit code. Each stream is one code and its end mark.
      for (final (stream, symbol) in const [(0x04, 0), (0x05, 1), (0x03, 2)]) {
        expect(
          zstdDecompress(directWeights([1, 1], stream: stream), maxOutput: 64),
          [symbol],
        );
      }
    });

    for (final (weights, message, why) in const [
      ([13, 1], 'Huffman weight is too high.', 'a weight over 12'),
      ([15], 'Huffman weight is too high.', 'the largest 4-bit weight'),
      ([0, 0, 0], 'Huffman weights are empty.', 'only zero weights'),
      ([12], 'Huffman code is too long.', 'codes longer than 11 bits'),
      ([3, 1], 'Huffman weights do not complete a tree.', 'no full tree'),
    ]) {
      test('$why: $message', () {
        expect(
          () => zstdDecompress(directWeights(weights), maxOutput: 64),
          refusedWith(message),
        );
      });
    }

    test('weights up to 12 pass the weight check itself', () {
      // 12 is allowed by the first check and refused only by the length
      // check, so the bound is the documented one and not off by one.
      expect(
        () => zstdDecompress(directWeights([12]), maxOutput: 64),
        isNot(refusedWith('Huffman weight is too high.')),
      );
    });

    test('every weight set of one to four symbols decodes or is refused', () {
      // 16 + 256 + 4096 + 65536 descriptions, each with a few stream
      // bytes: a damaged table may only end in ZstdFormatException (or a
      // result), never another error, a hang or an index out of range.
      var decoded = 0;
      var refused = 0;
      void tryAll(List<int> weights) {
        for (final stream in const [0x01, 0x04, 0x80, 0xFF]) {
          try {
            zstdDecompress(
              directWeights(weights, stream: stream),
              maxOutput: 64,
            );
            decoded++;
          } on ZstdFormatException {
            refused++;
          }
        }
      }

      for (var count = 1; count <= 4; count++) {
        final total = 1 << (4 * count);
        for (var code = 0; code < total; code++) {
          tryAll([for (var i = 0; i < count; i++) (code >> (4 * i)) & 15]);
        }
      }
      expect(decoded + refused, 4 * (16 + 256 + 4096 + 65536));
      expect(decoded, greaterThan(0), reason: 'legal sets still decode');
    }, timeout: const Timeout(Duration(minutes: 2)));
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
