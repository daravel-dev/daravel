@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// When the input transformers (`TrimStrings`, `ConvertEmptyStringsToNull`)
/// apply, checked against laravel/framework v10.48.29:
///
/// - `Foundation/Http/Middleware/TransformsRequest.php` 17–22: `handle()`
///   cleans the request once, when the middleware runs. Lines 30–39: the
///   query bag, then the JSON bag (or the form bag). Lines 59–82:
///   `cleanArray($value, $key.'.')`, so the key a transformer sees is the
///   dotted path.
/// - `Foundation/Http/Middleware/TrimStrings.php` 50–56: `except` is
///   compared with that dotted key (`in_array($key, $this->except, true)`).
/// - `Http/Request.php` 350–355: `merge()` adds to `getInputSource()`, the
///   bag cleaned earlier; 376–381: `replace()` replaces it. Neither runs a
///   transformer, so what they add stays as given.
/// - `Http/Concerns/InteractsWithInput.php` 301–306: `input()` is the input
///   source plus the query, the source winning.
void main() {
  Future<void> run(Middleware middleware, Request request) =>
      middleware.handle(request, (r) async => Response.text('ok'));

  Request post(Map<String, Object?> json, {Map<String, String>? query}) =>
      Request.fake(method: 'POST', path: '/x', json: json, query: query);

  test('input merged after TrimStrings and ConvertEmptyStringsToNull stays '
      'as given (Request::merge, TransformsRequest::handle)', () async {
    final request = post({' kept ': 'x', 'name': ' Ana ', 'bio': ''});
    await run(const TrimStringsMiddleware(), request);
    await run(const ConvertEmptyStringsToNullMiddleware(), request);
    // A middleware such as a payload decryption merges what it opened.
    await request.merge({'title': ' Kelas 7 ', 'note': ''});
    final input = await request.all();
    expect(input['name'], 'Ana', reason: 'sent by the client: trimmed');
    expect(input['bio'], isNull, reason: 'sent by the client: converted');
    expect(input['title'], ' Kelas 7 ', reason: 'merged: as given');
    expect(input['note'], '', reason: 'merged: not converted to null');
    expect(await request.input<String>('title'), ' Kelas 7 ');
    final validated = await request.validate({'note': 'present'});
    expect(validated.toMap()['note'], '');
  });

  test('replace() keeps its input as given (Request::replace)', () async {
    final request = post({'name': ' Ana '});
    await run(const TrimStringsMiddleware(), request);
    request.replace({'name': ' Bo ', 'empty': ''});
    await run(const ConvertEmptyStringsToNullMiddleware(), request);
    final input = await request.all();
    // Trimming ran before the replace; converting ran after it, so it
    // reaches the replaced bag, as a middleware running later would.
    expect(input['name'], ' Bo ');
    expect(input['empty'], isNull);
  });

  test('merge() keeps the transformed values already there and overwrites '
      'by name', () async {
    final request = post({'name': ' Ana ', 'city': ' Denpasar '});
    await run(const TrimStringsMiddleware(), request);
    await request.merge({'name': ' Bo '});
    expect(await request.all(), {'name': ' Bo ', 'city': 'Denpasar'});
  });

  test('the query stays transformed, and the body still wins over it '
      '(InteractsWithInput::input)', () async {
    final request = post({'page': ' 9 '}, query: {'page': ' 2 ', 'q': ' x '});
    await run(const TrimStringsMiddleware(), request);
    await request.merge({'page': ' 3 '});
    final input = await request.all();
    expect(input['q'], 'x');
    expect(input['page'], ' 3 ');
    expect(request.queryString('page'), '2');
  });

  test('a transformer sees the dotted key, so except names a path '
      '(TransformsRequest::cleanArray, TrimStrings::transform)', () async {
    final keys = <String>[];
    final request =
        post({
          'password': ' top ',
          'user': {'password': ' nested ', 'name': ' Ana '},
          'tags': [' a ', ' b '],
        })..addInputTransformer((key, value) {
          keys.add(key);
          return value;
        });
    await run(const TrimStringsMiddleware(), request);
    final input = await request.all();
    expect(keys, [
      'password',
      'user.password',
      'user.name',
      'tags.0',
      'tags.1',
    ]);
    expect(input['password'], ' top ', reason: 'listed in except');
    expect(
      (input['user']! as Map<String, Object?>)['password'],
      'nested',
      reason: '`user.password` is not `password`',
    );
    expect(input['tags'], ['a', 'b']);
    final only = post({
      'user': {'password': ' nested '},
    });
    await run(const TrimStringsMiddleware(except: {'user.password'}), only);
    expect(await only.input<String>('user.password'), ' nested ');
  });

  test('the default except is Laravel\'s: current_password, password and '
      'password_confirmation (TrimStrings::\$except)', () async {
    // laravel/framework v10.48.29 Foundation/Http/Middleware/TrimStrings.php
    // 16–20, and the same list in v11 and v12.
    final request = post({
      'current_password': ' old ',
      'password': ' new ',
      'password_confirmation': ' new ',
      'name': ' Ana ',
    });
    await run(const TrimStringsMiddleware(), request);
    expect(await request.all(), {
      'current_password': ' old ',
      'password': ' new ',
      'password_confirmation': ' new ',
      'name': 'Ana',
    });
    expect(TrimStringsMiddleware.defaultExcept, {
      'current_password',
      'password',
      'password_confirmation',
    });
  });
}
