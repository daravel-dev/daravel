import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Vectors written by PHP 8.4's `serialize()`.
void main() {
  group('PHP serialize()', () {
    final vectors = <(Object?, String)>[
      (null, 'N;'),
      (true, 'b:1;'),
      (false, 'b:0;'),
      (42, 'i:42;'),
      (-7, 'i:-7;'),
      (0.1, 'd:0.1;'),
      (1.0, 'd:1;'),
      (1e21, 'd:1.0E+21;'),
      ('héllo "x"', 's:10:"héllo "x"";'),
      ([1, 'a', null], 'a:3:{i:0;i:1;i:1;s:1:"a";i:2;N;}'),
      (
        {
          'a': 1,
          'b': {'c': true},
        },
        'a:2:{s:1:"a";i:1;s:1:"b";a:1:{s:1:"c";b:1;}}',
      ),
      ({3: 'x', 5: 'y'}, 'a:2:{i:3;s:1:"x";i:5;s:1:"y";}'),
      (<Object?>[], 'a:0:{}'),
    ];

    test('encodes as PHP does', () {
      for (final (value, php) in vectors) {
        expect(PhpSerializer.encode(value), php, reason: '$value');
      }
    });

    test('decodes what PHP wrote', () {
      for (final (value, php) in vectors) {
        final decoded = PhpSerializer.decode(php);
        expect(
          decoded,
          value is Map
              ? {for (final e in value.entries) '${e.key}': e.value}
              : value,
          reason: php,
        );
      }
    });

    test('objects become maps of their properties; enums their names', () {
      expect(
        PhpSerializer.decode(
          'O:3:"Foo":3:{s:8:"\u0000Foo\u0000bar";i:1;s:6:"\u0000*\u0000baz";'
          's:2:"é";s:3:"qux";a:2:{i:0;i:1;i:1;i:2;}}',
        ),
        {
          'bar': 1,
          'baz': 'é',
          'qux': [1, 2],
        },
      );
      expect(PhpSerializer.decode('O:8:"stdClass":1:{s:1:"a";i:1;}'), {'a': 1});
      expect(PhpSerializer.decode('E:11:"Suit:Hearts";'), 'Suit:Hearts');
    });

    test('refuses what is not serialize() output', () {
      for (final bad in ['s:5:"ab";', 'i:x;', 'a:1:{i:0;}', 'N;N;', 'r:1;']) {
        expect(
          () => PhpSerializer.decode(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('values that are not JSON go through toJson()', () {
      expect(
        PhpSerializer.encode({'at': _Stamp()}),
        'a:1:{s:2:"at";a:1:{s:1:"t";i:1;}}',
      );
    });
  });

  group('RedisStore values', () {
    final php = RedisStore(
      RedisClient(const RedisConnectionConfig()),
      serializer: RedisSerializer.php,
    );
    final json = RedisStore(RedisClient(const RedisConnectionConfig()));

    test('numbers stay numbers, so INCRBY and Laravel read them', () {
      for (final store in [php, json]) {
        expect(store.encode(5), '5');
        expect(store.encode(0.5), '0.5');
      }
    });

    test('the rest as JSON or serialize(); both are read', () {
      expect(json.encode('hi'), '"hi"');
      expect(php.encode('hi'), 's:2:"hi";');
      expect(php.encode([1]), 'a:1:{i:0;i:1;}');
      for (final raw in ['"hi"', 's:2:"hi";']) {
        expect(RedisStore.decode(raw), 'hi');
      }
      expect(RedisStore.decode('a:1:{i:0;i:1;}'), [1]);
      expect(RedisStore.decode('12'), 12);
      // Neither: the raw text.
      expect(RedisStore.decode('a:b'), 'a:b');
      expect(RedisStore.decode('plain'), 'plain');
    });
  });
}

final class _Stamp {
  Map<String, Object?> toJson() => {'t': 1};
}
