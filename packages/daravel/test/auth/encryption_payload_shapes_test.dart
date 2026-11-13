import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A payload comes from outside (a cookie, an `X-XSRF-TOKEN` header): any
/// shape of it is refused with a [DecryptException], never another error.
/// As Laravel's `Encrypter::validPayload`, `iv`, `value` and `mac` must be
/// strings, and `tag` one when it is set.
void main() {
  final key = List<int>.generate(32, (i) => i);
  final crypts = [
    Encrypter(key, cipher: .aes256cbc),
    Encrypter(key, cipher: .aes256gcm),
  ];

  String encode(Object? json) => base64.encode(utf8.encode(jsonEncode(json)));

  test('a field of the wrong type is a DecryptException', () async {
    final iv = base64.encode(List<int>.filled(16, 1));
    for (final payload in <Object?>[
      {'iv': '', 'value': '', 'mac': 123},
      {'iv': '', 'value': '', 'mac': '', 'tag': 123},
      {'iv': '', 'value': '', 'mac': '', 'tag': <Object?>[]},
      {'iv': '', 'value': '', 'mac': '', 'tag': <String, Object?>{}},
      {'iv': iv, 'value': 'AAAA', 'mac': false},
      {'iv': iv, 'value': 'AAAA'}, // No mac.
      {'iv': iv, 'value': 'AAAA', 'mac': null},
      {'iv': 1, 'value': '', 'mac': ''},
      {'iv': '', 'value': null, 'mac': ''},
      [1, 2, 3],
      'text',
      null,
    ]) {
      for (final crypt in crypts) {
        await expectLater(
          crypt.decryptString(encode(payload)),
          throwsA(isA<DecryptException>()),
          reason: jsonEncode(payload),
        );
        await expectLater(
          crypt.decrypt<Object?>(encode(payload)),
          throwsA(isA<DecryptException>()),
          reason: jsonEncode(payload),
        );
      }
    }
  });

  test('an explicit null tag is no tag, as in Laravel', () async {
    for (final crypt in crypts) {
      final good = jsonDecode(
        utf8.decode(base64.decode(await crypt.encryptString('x'))),
      ) as Map<String, Object?>;
      if ((good['tag']! as String).isEmpty) {
        expect(await crypt.decryptString(encode({...good, 'tag': null})), 'x');
      }
    }
  });

  test('100 000 random payloads: only DecryptException', () async {
    final random = Random(20261113);
    String base64Of(int length) =>
        base64.encode(List<int>.generate(length, (_) => random.nextInt(256)));
    Object? value(int depth) => switch (random.nextInt(depth > 2 ? 7 : 9)) {
      0 => null,
      1 => random.nextBool(),
      2 => random.nextInt(1 << 31) - (1 << 30),
      3 => random.nextDouble(),
      4 => base64Of(random.nextInt(40)),
      5 => String.fromCharCodes(
        List.generate(random.nextInt(12), (_) => random.nextInt(0x3000)),
      ),
      6 => base64Of([12, 16, 32][random.nextInt(3)]),
      7 => [for (var i = random.nextInt(4); i > 0; i--) value(depth + 1)],
      _ => {
        for (var i = random.nextInt(4); i > 0; i--)
          'k${random.nextInt(9)}': value(depth + 1),
      },
    };
    const fields = ['iv', 'value', 'mac', 'tag'];
    var refused = 0;
    for (var i = 0; i < 100000; i++) {
      final String payload;
      switch (i % 10) {
        case 0:
          // Not even base64 of JSON.
          payload = String.fromCharCodes(
            List.generate(random.nextInt(30), (_) => random.nextInt(128)),
          );
        case 1:
          payload = encode(value(0));
        default:
          payload = encode({
            for (final field in fields)
              if (random.nextInt(6) != 0) field: value(1),
            if (random.nextBool()) 'extra': value(1),
          });
      }
      final crypt = crypts[i % 2];
      try {
        await crypt.decryptString(payload);
        fail('decrypted a random payload: $payload');
      } on DecryptException {
        refused++;
      } on Object catch (error) {
        fail('${error.runtimeType} for $payload: $error');
      }
    }
    expect(refused, 100000);
  });

  test('payloads of both ciphers still decrypt', () async {
    for (final crypt in crypts) {
      expect(await crypt.decryptString(await crypt.encryptString('v')), 'v');
      expect(await crypt.decrypt<Object?>(await crypt.encrypt([1, 'a'])), [
        1,
        'a',
      ]);
    }
  });
}
