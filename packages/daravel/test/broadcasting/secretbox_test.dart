import 'dart:convert';
import 'dart:typed_data';

import 'package:daravel/src/broadcasting/secretbox.dart';
import 'package:test/test.dart';

/// Made by PHP 8.4's libsodium: sodium_crypto_secretbox($plain, $nonce,
/// $key) with a key of 32 0x07 bytes and the nonce 1, 2, ..., 24.
const Map<String, String> sodium = {
  '': 'X6UqN4fZvzfqFfxwRV//hQ==',
  'hi': 'IkytYq6OXcbtwgJrputhUvW9',
  '{"id":7,"status":"shipped"}':
      'S+SUQ9SzIbVelUT9JHPFDOb2pznVttS8bULZVAxBb5Ho737k51SGJO6meQ==',
};

void main() {
  final key = Uint8List.fromList(List.filled(32, 7));
  final nonce = Uint8List.fromList([for (var i = 1; i <= 24; i++) i]);

  test('secretbox gives libsodium\'s boxes, and opens them', () {
    for (final MapEntry(key: plain, value: box) in sodium.entries) {
      expect(
        base64.encode(Secretbox.seal(utf8.encode(plain), nonce, key)),
        box,
      );
      expect(
        utf8.decode(Secretbox.open(base64.decode(box), nonce, key)!),
        plain,
      );
    }
    // Across several 64-byte blocks.
    final long = 'Daravel ' * 20;
    expect(
      base64.encode(Secretbox.seal(utf8.encode(long), nonce, key)),
      '2SYHrz9YtuNRDy/3sf79Ctm1vDyB6Y+wC1DfVA5RcJOWrH/t+EGaYc7ldo+AHIsFXCC2yUyE8ezGgtn9qXsIGiTDrhvvbIoHWTpZjtjTzP8gFsBf2MYWFsImNEVtglBBrc80sEnhQAYdoercaXYvhWCA27w0jxZIFiSfA8dWXY0RqC4FgJLjSgUCR0/jElHfMiMn5Xi1max/FW086qQ89q9nCYBcKl+uxubfFbtZolY=',
    );
  });

  test('Poly1305 gives the RFC 8439 tag', () {
    List<int> hex(String h) => [
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16),
    ];
    expect(
      Secretbox.poly1305(
        utf8.encode('Cryptographic Forum Research Group'),
        hex('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b'),
      ),
      hex('a8061dc1305136c6c22b8baf0c0127a9'),
    );
  });

  test('a changed byte does not open', () {
    final box = Secretbox.seal(utf8.encode('secret'), nonce, key);
    box[20] ^= 1;
    expect(Secretbox.open(box, nonce, key), isNull);
  });

  test('the shared secret is pusher-php-server\'s', () {
    expect(
      base64.encode(
        PusherEncryption.sharedSecret(
          'private-encrypted-orders.7',
          List.filled(32, 0x2a),
        ),
      ),
      'YVE7dQHwfPrdsEpUgVuU+6tQOpGsbMMWjqZqVw8FTrs=',
    );
    final message = jsonDecode(
      PusherEncryption.encrypt(
        'private-encrypted-orders.7',
        '{"id":7}',
        List.filled(32, 0x2a),
      ),
    ) as Map<String, Object?>;
    expect(
      utf8.decode(
        Secretbox.open(
          base64.decode(message['ciphertext']! as String),
          base64.decode(message['nonce']! as String),
          PusherEncryption.sharedSecret(
            'private-encrypted-orders.7',
            List.filled(32, 0x2a),
          ),
        )!,
      ),
      '{"id":7}',
    );
  });
}
