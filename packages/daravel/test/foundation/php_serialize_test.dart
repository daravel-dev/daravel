import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Against `php -r 'echo serialize(...);'` output (PHP 8.1 to 8.4,
/// `serialize_precision = -1`).
void main() {
  group('phpSerialize', () {
    test('scalars', () {
      expect(phpSerialize(null), 'N;');
      expect(phpSerialize(true), 'b:1;');
      expect(phpSerialize(false), 'b:0;');
      expect(phpSerialize(42), 'i:42;');
      expect(phpSerialize(-7), 'i:-7;');
      expect(phpSerialize(1.5), 'd:1.5;');
      expect(phpSerialize(1.0), 'd:1;');
      expect(phpSerialize(0.1), 'd:0.1;');
      expect(phpSerialize(1e21), 'd:1.0E+21;');
      expect(phpSerialize(1.5e-7), 'd:1.5E-7;');
      expect(phpSerialize(double.nan), 'd:NAN;');
      expect(phpSerialize(double.negativeInfinity), 'd:-INF;');
      expect(phpSerialize('hello'), 's:5:"hello";');
      // Byte length, not character count; quotes are not escaped.
      expect(phpSerialize('café "x"'), 's:9:"café "x"";');
    });

    test('lists and maps are PHP arrays', () {
      expect(phpSerialize(['a', 2, null]), 'a:3:{i:0;s:1:"a";i:1;i:2;i:2;N;}');
      expect(
        phpSerialize({
          'id': 7,
          'roles': ['admin'],
          '5': 'x',
          '05': 'y',
        }),
        'a:4:{s:2:"id";i:7;s:5:"roles";a:1:{i:0;s:5:"admin";}'
        'i:5;s:1:"x";s:2:"05";s:1:"y";}',
      );
      expect(phpSerialize(<String, Object?>{}), 'a:0:{}');
    });

    test('objects round-trip and other types are refused', () {
      const object = PhpObject('stdClass', {'a': 1});
      expect(phpSerialize(object), 'O:8:"stdClass":1:{s:1:"a";i:1;}');
      expect(phpUnserialize(phpSerialize(object)), object);
      expect(() => phpSerialize(DateTime(2026)), throwsArgumentError);
      expect(() => phpSerialize(const Duration()), throwsArgumentError);
    });
  });

  group('phpUnserialize', () {
    test('reads what PHP writes', () {
      expect(phpUnserialize('N;'), isNull);
      expect(phpUnserialize('b:1;'), isTrue);
      expect(phpUnserialize('i:-3;'), -3);
      expect(phpUnserialize('d:2.5;'), 2.5);
      expect(phpUnserialize('d:INF;'), double.infinity);
      expect(phpUnserialize('s:9:"café "x"";'), 'café "x"');
      expect(phpUnserialize('a:2:{i:0;s:1:"a";i:1;s:1:"b";}'), ['a', 'b']);
      expect(phpUnserialize('a:0:{}'), <Object?>[]);
      // Not 0..n-1 in order: a map, integer keys as strings.
      expect(phpUnserialize('a:2:{i:1;s:1:"a";i:0;s:1:"b";}'), {
        '1': 'a',
        '0': 'b',
      });
      expect(
        phpUnserialize(
          'a:2:{s:6:"_token";s:3:"abc";s:6:"_flash";'
          'a:2:{s:3:"old";a:0:{}s:3:"new";a:0:{}}}',
        ),
        {
          '_token': 'abc',
          '_flash': {'old': <Object?>[], 'new': <Object?>[]},
        },
      );
    });

    test('a protected property keeps its mangled name', () {
      final object = phpUnserialize(
        'O:3:"Foo":2:{s:6:"\u0000*\u0000bar";i:1;'
        's:8:"\u0000Foo\u0000baz";i:2;}',
      ) as PhpObject;
      expect(object.className, 'Foo');
      expect(object.properties.keys, [
        '\u0000*\u0000bar',
        '\u0000Foo\u0000baz',
      ]);
    });

    test('rejects references, Serializable and malformed input', () {
      expect(() => phpUnserialize('r:1;'), throwsFormatException);
      expect(() => phpUnserialize('C:3:"Foo":0:{}'), throwsFormatException);
      expect(() => phpUnserialize('s:5:"abc";'), throwsFormatException);
      expect(() => phpUnserialize('i:1;x'), throwsFormatException);
      expect(() => phpUnserialize('{"json":true}'), throwsFormatException);
      expect(() => phpUnserialize(''), throwsFormatException);
    });

    test('looksPhpSerialized tells serialize() text from JSON', () {
      expect(looksPhpSerialized('a:1:{i:0;i:1;}'), isTrue);
      expect(looksPhpSerialized('N;'), isTrue);
      expect(looksPhpSerialized('s:1:"a";'), isTrue);
      expect(looksPhpSerialized('[1,2]'), isFalse);
      expect(looksPhpSerialized('"s:1"'), isFalse);
      expect(looksPhpSerialized('null'), isFalse);
    });
  });
}
