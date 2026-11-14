import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// DB-1 (Reviewer RSEQ 49): one redactor for every URL that can carry a
/// password (database, Redis, upstream), which needs no valid URL.
void main() {
  const secret = 'S3cr3tPW';

  test('the password is masked whatever the shape', () {
    for (final (url, expected) in [
      ('pgsql://u:$secret@h/db', 'pgsql://u:***@h/db'),
      ('pgsql://u:$secret@ss@h/db', 'pgsql://u:***@h/db'),
      ('pgsql://u:$secret/x?y#z@h/db', 'pgsql://u:***@h/db'),
      ('PGSQL://u:$secret@h/db', 'PGSQL://u:***@h/db'),
      ('mysql+ssl://u:$secret@h/db', 'mysql+ssl://u:***@h/db'),
      ('redis://:$secret@host', 'redis://:***@host'), // no user
      ('postgres://u:$secret@[::1/db', 'postgres://u:***@[::1/db'),
      // No `//`: the scheme cannot be told from a user name, so the user
      // is masked too (more, never less).
      ('pgsql:u:$secret@h/db', 'pgsql:***@h/db'),
      // RSEQ 67: the last `@` of the authority, so an `@` in the query
      // leaves the path and the query alone.
      ('pgsql://u:$secret@h/db?a=b@c', 'pgsql://u:***@h/db?a=b@c'),
      // RSEQ 53 #6: no valid scheme, and a password holding `:`.
      ('app:$secret@host/db', 'app:***@host/db'),
      ('postgres//app:$secret@host/db', 'postgres//app:***@host/db'),
      ('//app:$secret@bad host/db', '//app:***@bad host/db'),
      ('app:P1:$secret@host:5432/db', 'app:***@host:5432/db'),
      ('pgsql://app:P1:$secret@host/db', 'pgsql://app:***@host/db'),
      // A `://` after the `@` (in the query) is not the scheme's.
      ('app:$secret@host/?next=https://x', 'app:***@host/?next=https://x'),
      // A `://` inside the password: not a scheme's, since what precedes
      // it is no scheme (Tech Lead, SEQ 208 reply).
      ('app:pa://$secret@host/db', 'app:***@host/db'),
      ('//app:pa://$secret@host', '//app:***@host'),
      ('pgsql://app:pa://$secret@h/db', 'pgsql://app:***@h/db'),
      ('1x://app:$secret@h', '1x:***@h'), // a scheme starts with a letter
    ]) {
      expect(redactUrlPassword(url), expected, reason: url);
    }
  });

  test('redactUrl masks sensitive pairs in the query and the fragment', () {
    for (final (url, expected) in [
      (
        'https://app.test/cb#access_token=$secret&id_token=$secret&state=s1',
        'https://app.test/cb#access_token=***&id_token=***&state=s1',
      ),
      (
        'https://h/p?token=$secret&page=2#api_key=$secret',
        'https://h/p?token=***&page=2#api_key=***',
      ),
      ('https://h/p#section-2', 'https://h/p#section-2'), // no pairs
      // A `?` after the `#` belongs to the fragment, read as pairs too.
      ('https://h/p#a?token=x', 'https://h/p#a?token=***'),
      ('https://h/p?page=1#top', 'https://h/p?page=1#top'),
    ]) {
      expect(redactUrl(url), expected, reason: url);
    }
  });

  group('RSEQ 67', () {
    test('an `@` after the authority does not swallow the URL', () {
      for (final (url, expected) in [
        (
          'https://host:8080/p?token=$secret&email=a@b',
          'https://host:8080/p?token=***&email=a@b',
        ),
        ('https://h/a@b/c', 'https://h/a@b/c'),
        // A password holding `/`, `?` or `#` is still masked whole.
        ('pgsql://u:pa/$secret@h/db', 'pgsql://u:***@h/db'),
        ('pgsql://u:pa?$secret@h/db', 'pgsql://u:***@h/db'),
        ('pgsql://u:pa#$secret@h/db', 'pgsql://u:***@h/db'),
        ('pgsql://u:p@$secret@h/db', 'pgsql://u:***@h/db'),
      ]) {
        expect(redactUrl(url), expected, reason: url);
      }
    });

    test('pairs split at `;`, nested queries, and a nested user info', () {
      for (final (url, expected) in [
        ('https://h/p?page=1;token=$secret', 'https://h/p?page=1;token=***'),
        (
          'https://h/p?next=https://other/cb?token=$secret',
          'https://h/p?next=https://other/cb?token=***',
        ),
        (
          'https://app/cb?redirect_uri=https://u:$secret@evil/cb?access_token=$secret',
          'https://app/cb?redirect_uri=https://u:***@evil/cb?access_token=***',
        ),
      ]) {
        expect(redactUrl(url), expected, reason: url);
      }
    });

    test('names compared decoded, without control characters', () {
      for (final (url, expected) in [
        ('https://h/p?token%3D$secret', 'https://h/p?token=***'),
        ('https://h/p?t%00oken=$secret', 'https://h/p?t%00oken=***'),
        ('https://h/p?tok%ZZen=$secret', 'https://h/p?tok%ZZen=***'),
        ('https://h/p?Api%5FKey=$secret', 'https://h/p?Api%5FKey=***'),
      ]) {
        expect(redactUrl(url), expected, reason: url);
      }
    });

    test('short names match whole only', () {
      expect(
        redactUrl(
          'https://h/p?sig=$secret&key=$secret&code=$secret&auth=$secret'
          '&pass=$secret&design=1&keyword=2&signin=3',
        ),
        'https://h/p?sig=***&key=***&code=***&auth=***&pass=***'
        '&design=1&keyword=2&signin=3',
      );
    });

    test('known limits stay as documented', () {
      // A name encoded twice is not read as `token` (nor by a server).
      expect(
        redactUrl('https://h/p?%2574oken=$secret'),
        'https://h/p?%2574oken=$secret',
      );
      // A fragment without `=` is left alone.
      expect(redactUrl('https://h/p#$secret'), 'https://h/p#$secret');
    });

    test('1 MiB of each shape takes one pass', () {
      const mib = 1024 * 1024;
      for (final url in [
        'https://h/p?${'a=b&' * (mib ~/ 4)}',
        'https://h/p?${'a=b;' * (mib ~/ 4)}token=$secret',
        'https://${'u' * mib}:$secret@h/db',
        'https://h/${'a@' * (mib ~/ 2)}',
        'pgsql://u:${'/' * mib}$secret@h',
        'https://h/p#${'x=1&' * (mib ~/ 4)}',
        'https://h/p?${'%ZZ' * (mib ~/ 3)}token=$secret',
      ]) {
        final watch = Stopwatch()..start();
        final masked = redactUrl(url);
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(masked, isNot(contains(secret)), reason: url.substring(0, 40));
      }
    });
  });

  test('nothing to mask: the URL is returned as it is', () {
    for (final url in [
      'pgsql://u@h/db', // user info without a password
      'pgsql://h:5432/db', // a port, no user info
      'sqlite::memory:',
      'sqlite:///srv/app.sqlite',
      'not a url',
      '',
    ]) {
      expect(redactUrlPassword(url), url, reason: url);
    }
  });

  test('loneUserIsPassword masks a user info without `:`', () {
    expect(
      redactUrlPassword('redis://$secret@h', loneUserIsPassword: true),
      'redis://***@h',
    );
    expect(
      redactUrlPassword('redis://h:6379', loneUserIsPassword: true),
      'redis://h:6379',
    );
  });

  test(
    'a malformed UPSTREAM_URL stops the boot without its password',
    () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'UPSTREAM_URL': 'http://u:$secret@[::1/legacy?token=$secret',
          })
          .withLogLevel(LogLevel.critical)
          .withRouting(web: (router) {})
          .withUpstream()
          .create();
      Object? error;
      try {
        await app.boot();
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<ConfigException>());
      expect('$error', isNot(contains(secret)));
      expect('$error', contains('http://u:***@[::1/legacy'));
    },
  );
}
