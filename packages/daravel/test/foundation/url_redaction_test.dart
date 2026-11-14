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
      // An `@` in the query masks more, never less.
      ('pgsql://u:$secret@h/db?a=b@c', 'pgsql://u:***@c'),
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
            'UPSTREAM_URL': 'http://u:$secret@[::1/legacy',
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
