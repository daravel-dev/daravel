import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A JSON `\uXXXX` escape, built from a backslash and [hex].
String u(String hex) => '${String.fromCharCode(0x5C)}u$hex';

void main() {
  group('phpJsonFromDart', () {
    test('escapes like json_encode with default flags', () {
      // What `php -r 'echo json_encode([...]);'` prints for these values.
      expect(
        phpJsonFromDart(
          jsonEncode({'url': 'a/b', 'name': 'Café 😀', 'q': r'x"/\y'}),
        ),
        '{"url":"a\\/b","name":"Caf${u('00e9')} ${u('d83d')}${u('de00')}",'
        r'"q":"x\"\/\\y"}',
      );
    });

    test('empty maps become [] only outside strings, when asked', () {
      final json = jsonEncode({
        'meta': <String, Object?>{},
        'list': <Object?>[],
        'text': '{}',
        'nested': [<String, Object?>{}],
      });
      expect(
        phpJsonFromDart(json, emptyMapsAsArrays: true),
        '{"meta":[],"list":[],"text":"{}","nested":[[]]}',
      );
      expect(phpJsonFromDart(json), json);
    });

    test('returns the input unchanged when nothing needs escaping', () {
      const json = '{"a":1,"b":"plain"}';
      expect(identical(phpJsonFromDart(json), json), isTrue);
    });

    test('a key with a slash or non-ASCII is escaped too', () {
      expect(phpJsonFromDart(jsonEncode({'a/é': 1})), '{"a\\/${u('00e9')}":1}');
    });
  });

  test('Response.json(phpCompatible: true) writes PHP bytes', () async {
    final response = Response.json({
      'when': DateTime.utc(2026, 10, 29),
      'path': '/x',
      'tags': <String, Object?>{},
    }, phpCompatible: true);
    expect(
      await response.bodyText(),
      r'{"when":"2026-10-29T00:00:00.000000Z","path":"\/x","tags":[]}',
    );
    expect(await Response.json({'path': '/x'}).bodyText(), '{"path":"/x"}');
  });

  test('phpRawUrlEncode is rawurlencode', () {
    expect(phpRawUrlEncode('a b+c/é~'), 'a%20b%2Bc%2F%C3%A9~');
  });
}
