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
      ('pgsql:u:$secret@h/db', 'pgsql:u:***@h/db'), // no `//`
      // An `@` in the query masks more, never less.
      ('pgsql://u:$secret@h/db?a=b@c', 'pgsql://u:***@c'),
    ]) {
      expect(redactUrlPassword(url), expected, reason: url);
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
