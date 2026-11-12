import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A JSON body that is a list at the top reads as Laravel 13 reads it:
/// `$request->all()` keys the elements 0, 1, ..., `input('0.email')` and
/// rules on `*.email` reach them, and next to the query the body wins key
/// by key (`input + query`).
///
/// The golden (`fixtures/laravel_json_top_level_list.json`) was run through
/// Laravel 13.40 on PHP 8.3 (`Request::create` with a JSON body).
void main() {
  final golden =
      (jsonDecode(
            File('test/http/fixtures/laravel_json_top_level_list.json')
                .readAsStringSync(),
          ) as Map<String, Object?>)['cases']!
          as List<Object?>;

  // PHP's array at the top as Daravel's input: a list is keyed '0', '1',
  // ...; inside it, lists stay lists, as in any JSON body.
  Object? asInput(Object? php) => switch (php) {
    final List<Object?> list => <String, Object?>{
      for (final (i, v) in list.indexed) '$i': v,
    },
    final Map<String, Object?> map => <String, Object?>{
      for (final MapEntry(:key, :value) in map.entries) key: value,
    },
    _ => php,
  };

  for (final c in golden.cast<Map<String, Object?>>()) {
    final label = c['label']! as String;
    test(label, () async {
      Request request() => Request.fake(
        method: 'POST',
        path:
            '/probe${(c['query']! as String).isEmpty ? '' : '?${c['query']}'}',
        body: c['body']! as String,
        headers: {'content-type': 'application/json'},
      );
      final all = await request().all();
      expect(all, asInput(c['all']), reason: 'all()');
      expect(all.keys.toList(), [
        for (final k in c['keys']! as List<Object?>) '$k',
      ], reason: 'the order of the keys');
      expect(
        await request().input<Object?>('0.email'),
        c['input_0_email'],
        reason: "input('0.email')",
      );
      // input('1') is a list element: PHP gives the list itself.
      final one = c['input_1'];
      final readOne = await request().input<Object?>('1');
      expect(
        one is List<Object?> ? readOne : asInput(readOne),
        one is List<Object?> ? one : asInput(one),
        reason: "input('1')",
      );
      expect(await request().has('0'), c['has_0'], reason: "has('0')");
      for (final (key, rules) in [
        ('errors_star_email', {'*.email': 'required|email'}),
        ('errors_required_0', {'0': 'required'}),
        ('errors_array_min', {'*': 'array'}),
      ]) {
        final errors = await Validator(all, rules).run();
        final expected = (c[key]! as Map<String, Object?>).map(
          (k, v) => MapEntry(k, (v! as List<Object?>).cast<String>()),
        );
        expect(errors, expected, reason: '$key $rules');
      }
    });
  }

  test('a list body is no longer dropped from all()', () async {
    final request = Request.fake(
      method: 'POST',
      body: '[{"email":"a@x.com"}]',
      headers: {'content-type': 'application/json'},
    );
    expect(await request.all(), {
      '0': {'email': 'a@x.com'},
    });
    expect(await request.body(), [
      {'email': 'a@x.com'},
    ], reason: 'body() still gives the decoded list');
  });
}
