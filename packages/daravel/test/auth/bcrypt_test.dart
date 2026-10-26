import 'dart:typed_data';

import 'package:bcrypt/bcrypt.dart' as reference;
import 'package:daravel/src/auth/bcrypt.dart';
import 'package:daravel/src/auth/native_crypt.dart';
import 'package:test/test.dart';

/// Made by PHP 8.4: `password_hash($p, PASSWORD_BCRYPT, ['cost' => 4])`
/// and `crypt($p, '$2a$05$...')`.
const List<(String, String, String)> php = [
  (
    'secret-123',
    r'$2y$04$SvWIlVZ5Rzn8flPug7V5r.Y5uStXgmLyM6AzDuPRM1UDnDwn4STmq',
    r'$2a$05$7Zni9yqZjD5eQNN7SlORA.at3U3rIQw79cmPZFc0WAcwjUf6k2rha',
  ),
  (
    '',
    r'$2y$04$Xibi5p2znXFhB8s7g2T6H.sbSkiJfpk91aW1Di47C/oQFIbrVqJLi',
    r'$2a$05$RaM.xjQF8D4SKLmRsNVo2uuadyQxEw8.la4bdRD5o15vg3mcuYpDW',
  ),
  (
    'pässwörd 🔑',
    r'$2y$04$xjbJ6wc7NmFvE7w.JO871OjdhTFSldCdAOElvMaI7./MSL6gb4B4K',
    r'$2a$05$jAICm9RecyCBkp71oIMjyO0nntyuE5XlHCgJVFXQf1IpzSUY9Xs6m',
  ),
  (
    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    r'$2y$04$DRtEJQiqtCE/oTAcf23Wz.Mk6YIyvnIWEnDL8znRc7w7IlpFajIRq',
    r'$2a$05$mPz.o7j.tEz8TNSp0ZcAMetlysoI.2ageVKI3WnRbWwxre6a9Tug2',
  ),
];

void main() {
  for (final native in [false, true]) {
    group(native ? 'native (libcrypt)' : 'Dart', () {
      final skip = native && !NativeCrypt.available
          ? 'libcrypt.so.1 is not available here'
          : null;

      test('verifies hashes made by PHP', () {
        for (final (password, y, a) in php) {
          expect(Bcrypt.verify(password, y, native: native), isTrue);
          expect(Bcrypt.verify(password, a, native: native), isTrue);
          expect(
            Bcrypt.verify('${password}0', y, native: native),
            password.length >= 72,
          );
        }
      }, skip: skip);

      test('only the first 72 bytes count, as in PHP', () {
        final long = 'x' * 80;
        final hashed = Bcrypt.hash(long, cost: 4);
        expect(Bcrypt.verify('x' * 72, hashed, native: native), isTrue);
        expect(Bcrypt.verify('x' * 71, hashed, native: native), isFalse);
      }, skip: skip);
    });
  }

  test(
    'the Dart and native paths give the same hash',
    () {
      final salt = Uint8List.fromList(List.generate(16, (i) => i * 13));
      for (final password in ['secret', '', 'pässwörd 🔑', 'y' * 90]) {
        expect(
          Bcrypt.hashWithSalt(password, salt, cost: 5),
          Bcrypt.hashWithSalt(password, salt, cost: 5, native: false),
        );
      }
    },
    skip: NativeCrypt.available ? null : 'libcrypt.so.1 is not available here',
  );

  test('agrees with an independent implementation (package:bcrypt)', () {
    for (final password in ['secret', '', 'pässwörd 🔑', 'z' * 72]) {
      final ours = Bcrypt.hash(password, cost: 5);
      expect(reference.BCrypt.checkpw(password, ours), isTrue);
      final theirs = reference.BCrypt.hashpw(
        password,
        reference.BCrypt.gensalt(prefix: r'$2y', logRounds: 5),
      );
      expect(Bcrypt.verify(password, theirs, native: false), isTrue);
    }
  });

  test('writes \$2y\$ with the cost and a fresh salt', () {
    final first = Bcrypt.hash('secret', cost: 4);
    final second = Bcrypt.hash('secret', cost: 4);
    expect(first, matches(RegExp(r'^\$2y\$04\$[./A-Za-z0-9]{53}$')));
    expect(first, isNot(second));
  });

  test('malformed hashes and bad costs never match', () {
    for (final hashed in [
      '',
      'plain',
      r'$2y$04$short',
      r'$2x$04$SvWIlVZ5Rzn8flPug7V5r.Y5uStXgmLyM6AzDuPRM1UDnDwn4STmq',
      r'$2y$03$SvWIlVZ5Rzn8flPug7V5r.Y5uStXgmLyM6AzDuPRM1UDnDwn4STmq',
      r'$2y$04$SvWIlVZ5Rzn8flPug7V5r.Y5uStXgmLyM6AzDuPRM1UDnDwn4STm!',
    ]) {
      expect(Bcrypt.verify('secret-123', hashed), isFalse, reason: hashed);
    }
    expect(() => Bcrypt.hash('x', cost: 3), throwsArgumentError);
  });
}
