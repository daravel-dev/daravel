import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `QueryBuilder.streamJson` through the `DB` facade in a real route: the
/// body is written after the handler returned, so the page queries run
/// while the server pipes the stream, over the socket (ServerEngine) and
/// through `Application.handle`.
void main() {
  late Directory dir;
  late Application app;
  late ServerEngine engine;
  late HttpClient client;
  final rows = [
    for (var i = 1; i <= 7; i++) {'id': i, 'name': 'row $i'},
  ];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('daravel_stream_json_');
    app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': p.join(dir.path, 'app.sqlite'),
        })
        .withRouting(
          api: (r) {
            r.get(
              '/rows',
              (_) => Response.streamJson(
                DB.table('items').select(['id', 'name']).orderBy('id').lazy(2),
              ),
            );
            r.get(
              '/rows/raw',
              (_) => Response.stream(
                DB
                    .table('items')
                    .select(['id', 'name'])
                    .orderBy('id')
                    .streamJson(chunk: 3),
                contentType: 'application/json',
              ),
            );
          },
        )
        .create();
    await app.boot();
    await app.run(() async {
      await DB.statement(
        'CREATE TABLE items ("id" INTEGER PRIMARY KEY, "name" TEXT)',
      );
      for (final row in rows) {
        await DB.table('items').insert(row);
      }
    });
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.error),
    );
    await engine.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await engine.stop();
    await app.shutdown();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file for a moment.
    }
  });

  Future<(HttpClientResponse, String)> get(String path) async {
    final request = await client.get('127.0.0.1', engine.port!, path);
    final response = await request.close();
    return (response, await response.transform(utf8.decoder).join());
  }

  for (final path in ['/api/rows', '/api/rows/raw']) {
    test('$path streams every page over the socket', () async {
      final (response, body) = await get(path);
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(body), rows);
    });

    test('$path streams every page through Application.handle', () async {
      final response = await app.handle(Request.fake(path: path));
      expect(response.status, 200);
      final body = await utf8.decodeStream(
        (response.body as StreamBody).stream,
      );
      expect(jsonDecode(body), rows);
    });
  }
}
