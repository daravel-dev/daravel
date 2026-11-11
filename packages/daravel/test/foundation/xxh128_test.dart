import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The sanity buffer of xxHash's own tests (`tests/sanity_test.c`
/// `fillTestBuffer`, v0.8.2): byte i is the top byte of PRIME32 * PRIME64^i.
Uint8List sanityBuffer(int length) {
  final buffer = Uint8List(length);
  var byteGen = 2654435761; // PRIME32
  const prime64 = 0x9E3779B185EBCA8D; // 11400714785074694797
  for (var i = 0; i < length; i++) {
    buffer[i] = (byteGen >>> 56) & 0xFF;
    byteGen *= prime64;
  }
  return buffer;
}

/// XXH3-128 (G1.5 d): the official test vectors and PHP's `hash('xxh128')`.
void main() {
  final fixtures = '${Directory.current.path}/test/foundation/fixtures';

  test('the official sanity vectors of xxHash v0.8.2, seed 0, lengths 0 to '
      '4161 (every length path and block boundary)', () {
    // tests/sanity_test_vectors.h, XSUM_XXH128_testdata, seed 0; written
    // here as the canonical hex (high half first), as PHP prints it.
    final vectors = (jsonDecode(
      File('$fixtures/xxh128_sanity_vectors.json').readAsStringSync(),
    ) as List<Object?>).cast<Map<String, Object?>>();
    expect(vectors, hasLength(greaterThan(50)));
    final buffer = sanityBuffer(4161);
    for (final vector in vectors) {
      final len = vector['len']! as int;
      expect(
        Xxh128.hexOf(Uint8List.sublistView(buffer, 0, len)),
        vector['xxh128'],
        reason: 'length $len',
      );
    }
  });

  test("PHP's hash('xxh128', …) (PHP 8.2.33, in the interop harness image), "
      'UTF-8 strings across the length paths', () {
    final lines = File('$fixtures/xxh128_php.jsonl')
        .readAsLinesSync()
        .where((line) => line.startsWith('{'));
    var checked = 0;
    for (final line in lines) {
      final row = jsonDecode(line) as Map<String, Object?>;
      final input = row['input']! as String;
      expect(utf8.encode(input), hasLength(row['len']));
      expect(Xxh128.hex(input), row['xxh128'], reason: 'input "$input"');
      checked++;
    }
    expect(checked, 16);
  });
}
