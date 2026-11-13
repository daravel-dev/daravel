import 'dart:convert';
import 'dart:typed_data';

import 'package:daravel_reverb_client/src/secretbox.dart';
import 'package:test/test.dart';

import 'secretbox_vectors.dart';

Uint8List hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The hand-written XSalsa20-Poly1305 against independent references: it
/// must be NaCl's `crypto_secretbox`, or encrypted channels do not open.
///
/// No `dart:io` here: the same vectors run on the VM and in a browser
/// (`dart test -p chrome test/secretbox_test.dart`), where integers are
/// JavaScript numbers. secretbox_vectors_test.dart checks the vectors
/// against the fixture files.
void main() {
  test("NaCl's secretbox test vector (libsodium 1.0.20 "
      'test/default/secretbox.c and .exp)', () {
    final key = hex(naclVector.key);
    final nonce = hex(naclVector.nonce);
    final message = hex(naclVector.message);
    expect(message, hasLength(131));
    expect(toHex(Secretbox.seal(message, nonce, key)), naclVector.box);
    expect(
      toHex(Secretbox.open(hex(naclVector.box), nonce, key)!),
      toHex(message),
    );
  });

  test('Poly1305: RFC 8439 §2.5.2', () {
    expect(
      toHex(
        Secretbox.poly1305(
          utf8.encode('Cryptographic Forum Research Group'),
          hex(
            '85d6be7857556d337f4452fe42d506a8'
            '0103808afb0db2fd4abff6af4149f51b',
          ),
        ),
      ),
      'a8061dc1305136c6c22b8baf0c0127a9',
    );
  });

  test("PHP's sodium_crypto_secretbox (PHP 8.2.33, libsodium 1.0.18, in the "
      'interop harness image): 14 lengths from 0 to 200', () {
    for (final row in phpVectors) {
      final key = hex(row.key);
      final nonce = hex(row.nonce);
      final message = hex(row.message);
      expect(message, hasLength(row.len));
      expect(
        toHex(Secretbox.seal(message, nonce, key)),
        row.box,
        reason: 'length ${row.len}',
      );
      expect(
        toHex(Secretbox.open(hex(row.box), nonce, key)!),
        toHex(message),
        reason: 'length ${row.len}',
      );
    }
    expect(phpVectors, hasLength(14));
  });

  test('one flipped bit anywhere in the box does not open', () {
    final key = Uint8List.fromList(List.filled(32, 9));
    final nonce = Uint8List.fromList(List.filled(24, 4));
    final box = Secretbox.seal(utf8.encode('a private event'), nonce, key);
    for (var i = 0; i < box.length; i++) {
      for (final bit in const [0x01, 0x80]) {
        final changed = Uint8List.fromList(box);
        changed[i] ^= bit;
        expect(
          Secretbox.open(changed, nonce, key),
          isNull,
          reason: 'byte $i, bit $bit',
        );
      }
    }
    expect(Secretbox.open(box.sublist(0, 15), nonce, key), isNull);
  });
}
