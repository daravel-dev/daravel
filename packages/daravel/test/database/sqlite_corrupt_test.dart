import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A database file that is not one (a corrupted header, another file at
/// the path): the connection fails with SQLite's error, a request on it is
/// a 500 that says nothing about the file, and the application still shuts
/// down. The temporary directory deletes afterwards: the handle of the
/// failed connection was closed (on Windows an open one locks the file).
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daravel_corrupt');
    file = File('${dir.path}/app.sqlite')
      ..writeAsBytesSync(
        // The 16-byte header is "SQLite format 3\0"; this is not.
        utf8.encode('NOT A DATABASE ${'x' * 200}'),
      );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Application build({required bool debug}) =>
      Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_DEBUG': '$debug',
            'DB_DATABASE': file.path,
          })
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) {
              router.get('/rows', (_) => DB.select('SELECT 1 AS one'));
            },
          )
          .create();

  test('the first query reports the file, not the server', () async {
    final app = build(debug: false);
    await app.boot();
    addTearDown(app.shutdown);
    await expectLater(
      app.run(() => DB.select('SELECT 1')),
      throwsA(
        predicate(
          (Object e) => '$e'.toLowerCase().contains('not a database'),
          "SQLite's own error",
        ),
      ),
    );
    final response = await app.handle(Request.fake(path: '/rows'));
    expect(response.status, 500);
    expect(await response.bodyText(), '{"message":"Server Error"}');
    // A later request fails the same way instead of hanging on a
    // half-open connection.
    expect((await app.handle(Request.fake(path: '/rows'))).status, 500);
  });

  test('with APP_DEBUG the body carries the error, and only then', () async {
    final app = build(debug: true);
    await app.boot();
    addTearDown(app.shutdown);
    final body = await (await app.handle(Request.fake(path: '/rows')))
        .bodyText();
    expect(body, contains('"exception"'));
    expect(body.toLowerCase(), contains('not a database'));
  });
}
