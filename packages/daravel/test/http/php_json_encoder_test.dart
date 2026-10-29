import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

enum Colour { red, green }

/// What `Response.encodePhpJson` did before the one-pass encoder: the
/// native encoder, the `phpJsonFromDart` rewrite and a marker for empty
/// PHP objects. Kept here as the oracle: the new encoder must write the
/// same bytes for every value.
String twoPass(Object? data) {
  const marker = '__daravel_php_empty_object_c3f19e7a42__';
  final text = JsonEncoder((Object? value) {
    if (value is PhpObject && value.properties.isEmpty) {
      return marker;
    }
    return toEncodable(value);
  }).convert(data);
  return phpJsonFromDart(
    text,
    emptyMapsAsArrays: true,
  ).replaceAll('"$marker"', '{}');
}

/// `Response._toEncodable`.
Object? toEncodable(Object? value) {
  if (value is DateTime) {
    return jsonDate(value);
  }
  if (value is JsonSerializable) {
    return value.toJson();
  }
  if (value is Enum) {
    return value.name;
  }
  if (value is PhpObject) {
    return value.properties;
  }
  throw JsonUnsupportedObjectError(value);
}

final class Point implements JsonSerializable {
  const Point(this.x);

  final int x;

  @override
  Map<String, Object?> toJson() => {'x': x, 'path': '/p/$x'};
}

/// Code units worth escaping, built from their numbers so the source stays
/// plain ASCII: control characters, the JSON specials, a slash, Latin-1,
/// a line separator, an emoji (surrogate pair) and a lone surrogate.
final List<String> alphabet = [
  'a',
  'Z',
  '0',
  ' ',
  '/',
  r'\',
  '"',
  '{}',
  '[]',
  String.fromCharCode(0x00),
  String.fromCharCode(0x08),
  String.fromCharCode(0x09),
  String.fromCharCode(0x0A),
  String.fromCharCode(0x0C),
  String.fromCharCode(0x0D),
  String.fromCharCode(0x1F),
  String.fromCharCode(0x7F),
  String.fromCharCode(0xE9),
  String.fromCharCode(0x2028),
  String.fromCharCodes([0xD83D, 0xDE00]),
  String.fromCharCode(0xD83D),
  String.fromCharCode(0xDE00),
];

Object? randomValue(Random random, int depth) {
  String text() => [
    for (var i = random.nextInt(8); i > 0; i--)
      alphabet[random.nextInt(alphabet.length)],
  ].join();
  final kind = random.nextInt(depth > 3 ? 9 : 13);
  switch (kind) {
    case 0:
      return null;
    case 1:
      return random.nextBool();
    case 2:
      return random.nextInt(1 << 20) - (1 << 19);
    case 3:
      return (random.nextInt(2000) - 1000) / 8;
    case 4:
      return text();
    case 5:
      return DateTime.utc(2026, 1 + random.nextInt(12), 1 + random.nextInt(28));
    case 6:
      return Colour.values[random.nextInt(2)];
    case 7:
      return const PhpObject('stdClass', {});
    case 8:
      return Point(random.nextInt(10));
    case 9:
      return [
        for (var i = random.nextInt(4); i > 0; i--)
          randomValue(random, depth + 1),
      ];
    case 10:
      return <String, Object?>{
        for (var i = random.nextInt(4); i > 0; i--)
          text(): randomValue(random, depth + 1),
      };
    case 11:
      return PhpObject('App\\Thing', {
        for (var i = 1 + random.nextInt(3); i > 0; i--)
          text(): randomValue(random, depth + 1),
      });
    default:
      return <String, Object?>{};
  }
}

void main() {
  group('PhpJsonEncoder', () {
    test('writes the bytes of the two-pass encoding for random values', () {
      final random = Random(58);
      for (var i = 0; i < 2000; i++) {
        final value = randomValue(random, 0);
        expect(
          Response.encodePhpJson(value),
          twoPass(value),
          reason: 'value #$i: $value',
        );
      }
    });

    test('escapes every character class as json_encode does', () {
      final text = alphabet.join();
      expect(Response.encodePhpJson({text: text}), twoPass({text: text}));
      // Spot checks against what `php -r 'echo json_encode(...)'` prints
      // (the escapes are built from their hex digits, so the source holds
      // no `\u` sequence an editor could decode).
      String u(String hex) => '${String.fromCharCode(0x5C)}u$hex';
      expect(
        Response.encodePhpJson('a/b${String.fromCharCode(0xE9)}'),
        '"a\\/b${u('00e9')}"',
      );
      expect(
        Response.encodePhpJson(String.fromCharCodes([0xD83D, 0xDE00])),
        '"${u('d83d')}${u('de00')}"',
      );
      expect(
        Response.encodePhpJson('${String.fromCharCode(0x1F)}\t\n'),
        '"${u('001f')}\\t\\n"',
      );
    });

    test('options: unescaped slashes and empty maps as objects', () {
      const value = {'path': '/x', 'meta': <String, Object?>{}};
      expect(
        const PhpJsonEncoder(escapeSlashes: false).convert(value),
        '{"path":"/x","meta":[]}',
      );
      expect(
        const PhpJsonEncoder(emptyMapsAsArrays: false).convert(value),
        r'{"path":"\/x","meta":{}}',
      );
    });

    test('rejects what dart:convert rejects', () {
      const encoder = PhpJsonEncoder();
      expect(
        () => encoder.convert(Object()),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(
        () => encoder.convert(double.nan),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(
        () => encoder.convert({1: 'int key'}),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      expect(() => encoder.convert(cyclic), throwsA(isA<JsonCyclicError>()));
      // The same list twice is not a cycle.
      final shared = [1];
      expect(encoder.convert([shared, shared]), '[[1],[1]]');
    });

    test('toEncodable is applied once per value', () {
      final encoder = PhpJsonEncoder(
        toEncodable: (value) => value is Point ? value.toJson() : 'other',
      );
      expect(
        encoder.convert([const Point(1), Object()]),
        r'[{"x":1,"path":"\/p\/1"},"other"]',
      );
      // A conversion that returns something unsupported fails too.
      expect(
        () => PhpJsonEncoder(toEncodable: (_) => Object()).convert(Object()),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
    });
  });
}
