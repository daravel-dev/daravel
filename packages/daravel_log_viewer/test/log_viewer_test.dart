import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_log_viewer/daravel_log_viewer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String jsonLine(
  int i, {
  String level = 'info',
  Map<String, Object?>? context,
}) => jsonEncode({
  'time': '2026-10-28T08:00:${(i % 60).toString().padLeft(2, '0')}.000Z',
  'level': level,
  'channel': 'app',
  'message': 'message $i',
  'context': ?context,
});

const String laravelLog =
    '''[2026-10-28 08:00:00] local.INFO: started {"user":1}
[2026-10-28 08:00:01] local.ERROR: Division by zero {"exception":"[object] (DivisionByZeroError(code: 0): Division by zero at /app/Http/Calc.php:12)"}
[stacktrace]
#0 /app/Http/Calc.php(12): divide()
#1 {main}
"}
[2026-10-28 08:00:02] local.WARNING: slow query
''';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_logs_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, String content) =>
      File(p.join(dir.path, name))..writeAsStringSync(content);

  group('entries', () {
    test('a Daravel JSON line', () {
      final entry = LogEntry.parse(
        jsonLine(1, level: 'error', context: {'request_id': 'r-1'}),
        10,
        5,
      );
      expect(entry.level, 'error');
      expect(entry.message, 'message 1');
      expect(entry.channel, 'app');
      expect(entry.context, {'request_id': 'r-1'});
      expect(entry.offset, 10);
    });

    test('a Laravel (Monolog) entry with its stack trace', () {
      final entry = LogEntry.parse(
        '[2026-10-28 08:00:01] production.ERROR: Boom {"x":1}\n#0 /app/a.php(1): f()\n#1 {main}',
        0,
        1,
      );
      expect(entry.level, 'error');
      expect(entry.channel, 'production');
      expect(entry.time, '2026-10-28 08:00:01');
      expect(entry.message, 'Boom {"x":1}');
      expect(entry.trace, '#0 /app/a.php(1): f()\n#1 {main}');
      expect(LogEntry.parse('plain text', 0, 1).level, 'unknown');
    });
  });

  group('reading from the end', () {
    test(
      'every entry once, newest first, across pages and tiny blocks',
      () async {
        final lines = [for (var i = 1; i <= 120; i++) jsonLine(i)];
        final file = write('daravel-2026-10-28.log', '${lines.join('\n')}\n');
        for (final block in [7, 64, 4096]) {
          final reader = ReverseLogReader(file.path, blockSize: block);
          final seen = <String>[];
          int? before;
          do {
            final page = await reader.page(before: before, limit: 25);
            seen.addAll(page.entries.map((e) => e.message));
            before = page.next;
          } while (before != null);
          expect(seen, [
            for (var i = 120; i >= 1; i--) 'message $i',
          ], reason: 'block $block');
        }
      },
    );

    test('multi-line Laravel entries, CRLF, no final newline', () async {
      final file = write(
        'laravel.log',
        laravelLog.replaceAll('\n', '\r\n').trimRight(),
      );
      final page = await ReverseLogReader(
        file.path,
        blockSize: 16,
      ).page(limit: 10);
      expect(
        [for (final e in page.entries) e.level],
        ['warning', 'error', 'info'],
      );
      final error = page.entries[1];
      expect(error.trace, contains('#0 /app/Http/Calc.php(12): divide()'));
      expect(error.trace, isNot(contains('\r')));
      expect(page.next, isNull);
    });

    test('levels and search filter; a scan limit pages on', () async {
      final file = write(
        'daravel-2026-10-27.log',
        [
          for (var i = 1; i <= 300; i++)
            jsonLine(i, level: i % 50 == 0 ? 'error' : 'info'),
        ].join('\n'),
      );
      final reader = ReverseLogReader(file.path, blockSize: 512);
      final errors = await reader.page(
        filter: const LogFilter(levels: {'error'}),
      );
      expect(
        [for (final e in errors.entries) e.message],
        [for (var i = 300; i >= 50; i -= 50) 'message $i'],
      );
      expect(errors.next, isNull);
      final found = await reader.page(
        filter: const LogFilter(search: 'MESSAGE 7'),
      );
      expect(found.entries.map((e) => e.message), contains('message 7'));
      final limited = await reader.page(
        filter: const LogFilter(levels: {'error'}),
        maxScanBytes: 2000,
      );
      expect(limited.entries, hasLength(lessThan(6)));
      expect(limited.next, isNotNull, reason: 'stopped by the scan limit');
    });

    test('the last entries of a large file in constant time', () async {
      final file = File(p.join(dir.path, 'big.log'));
      final sink = file.openWrite();
      final line = '${jsonLine(1, context: {'pad': 'x' * 400})}\n';
      for (var i = 0; i < 120000; i++) {
        sink.write(line);
      }
      await sink.close();
      expect(file.lengthSync(), greaterThan(50 * 1024 * 1024));
      final watch = Stopwatch()..start();
      final page = await ReverseLogReader(file.path).page(limit: 50);
      watch.stop();
      expect(page.entries, hasLength(50));
      expect(watch.elapsedMilliseconds, lessThan(500));
    });

    test('tail: appended entries, then a cleared file', () async {
      final file = write('daravel-2026-10-28.log', '${jsonLine(1)}\n');
      final entries = StreamIterator(
        ReverseLogReader(file.path).tail(
          from: file.lengthSync(),
          interval: const Duration(milliseconds: 20),
        ),
      );
      file.writeAsStringSync(
        '${jsonLine(2)}\n${jsonLine(3, level: 'error')}\n',
        mode: FileMode.append,
      );
      expect(await entries.moveNext(), isTrue);
      expect(entries.current.message, 'message 2');
      expect(await entries.moveNext(), isTrue);
      expect(entries.current.level, 'error');
      file.writeAsStringSync('${jsonLine(4)}\n');
      expect(await entries.moveNext(), isTrue);
      expect(entries.current.message, 'message 4');
      await entries.cancel();
    });
  });

  group('security', () {
    test('only .log files directly in the folder', () {
      write('daravel-2026-10-28.log', 'x');
      write('.env', 'APP_KEY=secret');
      final guard = PathGuard(dir.path);
      expect(guard.resolve('daravel-2026-10-28.log').existsSync(), isTrue);
      for (final name in [
        '../daravel-2026-10-28.log',
        '..\\x.log',
        'sub/x.log',
        '.env',
        '.hidden.log',
        'x.log\u0000.txt',
        '/etc/passwd',
        'C:\\Windows\\win.ini',
        'missing.log',
        '..log',
      ]) {
        expect(
          () => guard.resolve(name),
          throwsA(isA<LogFileRefused>()),
          reason: name,
        );
      }
      expect(
        [for (final f in guard.files()) p.basename(f.path)],
        ['daravel-2026-10-28.log'],
      );
    });

    test('secrets masked in context and text', () {
      final masker = Masker(LogViewerConfig.defaultMaskKeys);
      expect(
        masker.json({
          'user': 'ana',
          'Password': 'p',
          'nested': {
            'api_key': 'k',
            'list': [
              {'access_token': 't'},
            ],
          },
        }),
        {
          'user': 'ana',
          'Password': '********',
          'nested': {
            'api_key': '********',
            'list': [
              {'access_token': '********'},
            ],
          },
        },
      );
      expect(
        masker.text(
          'login password=hunter2&user=ana "token":"abc\\"d" Authorization: Bearer xyz',
        ),
        'login password=********&user=ana "token":"********" Authorization: ******** xyz',
      );
    });
  });

  group('HTTP', () {
    late Application app;
    late String logs;

    Future<Application> boot({
      Map<String, String> env = const {},
      List<Object> middleware = const [],
    }) async {
      logs = p.join(dir.path, 'storage', 'logs');
      Directory(logs).createSync(recursive: true);
      final application = Application.configure(basePath: dir.path)
          .withEnv({'APP_ENV': 'testing', 'LOG_LEVEL': 'error', ...env})
          .withLogViewer(middleware: middleware)
          .withMiddleware((m) => m.alias('allow', _Allow()))
          .withRouting(api: (_) {})
          .create();
      await application.boot();
      return application;
    }

    tearDown(() async => app.shutdown());

    Future<(int, Map<String, String>, String)> get(
      String path, {
      String method = 'GET',
    }) async {
      final response = await app.handle(
        Request.fake(method: method, path: path),
      );
      return (
        response.status,
        {
          for (final name in [
            'content-type',
            'content-security-policy',
            'content-disposition',
          ])
            name: response.headers.first(name) ?? '',
        },
        await response.bodyText(),
      );
    }

    test('the page, files and entries, masked', () async {
      app = await boot();
      File(p.join(logs, 'daravel-2026-10-27.log'))
          .writeAsStringSync('${jsonLine(1)}\n');
      File(p.join(logs, 'daravel-2026-10-28.log')).writeAsStringSync(
        '${jsonLine(1)}\n${jsonLine(2, level: 'error', context: {'password': 'p', 'id': 7})}\n',
      );
      final (status, headers, html) = await get('/log-viewer');
      expect(status, 200);
      expect(headers['content-type'], startsWith('text/html'));
      final nonce = RegExp("'nonce-([^']+)'")
          .firstMatch(headers['content-security-policy']!)![1];
      expect(html, contains('<script nonce="$nonce">'));
      expect(html, isNot(contains('http://')), reason: 'no external assets');

      final files = jsonDecode(
        (await get('/log-viewer/api/files')).$3,
      ) as Map<String, Object?>;
      expect((files['files']! as List).length, 2);
      expect(files['allow_delete'], false);

      final entries = jsonDecode(
        (await get(
          '/log-viewer/api/entries?file=daravel-2026-10-28.log&levels=error',
        )).$3,
      ) as Map<String, Object?>;
      final [entry] = entries['entries']! as List<Object?>;
      expect((entry! as Map)['context'], {'password': '********', 'id': 7});
      expect((await get('/log-viewer/api/entries?file=../../.env')).$1, 404);
      expect((await get('/log-viewer/api/entries?file=nope.log')).$1, 404);
    });

    test('downloads, deletes, the live tail', () async {
      app = await boot(env: {'LOG_VIEWER_ALLOW_DELETE': 'true'});
      final file = File(p.join(logs, 'daravel-2026-10-28.log'))
        ..writeAsStringSync('${jsonLine(1)}\n');
      final (status, headers, body) = await get(
        '/log-viewer/api/download?file=daravel-2026-10-28.log',
      );
      expect(status, 200);
      expect(
        headers['content-disposition'],
        contains('daravel-2026-10-28.log'),
      );
      expect(body, contains('message 1'));

      final response = await app.handle(
        Request.fake(
          path: '/log-viewer/api/tail?file=daravel-2026-10-28.log&levels=error',
        ),
      );
      expect(response.headers.first('content-type'), 'text/event-stream');
      final lines = StreamIterator(
        (response.body as StreamBody).stream
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      file.writeAsStringSync(
        '${jsonLine(2)}\n${jsonLine(3, level: 'error')}\n',
        mode: FileMode.append,
      );
      var event = '';
      while (await lines.moveNext()) {
        if (lines.current.startsWith('data: ')) {
          event = lines.current;
          break;
        }
      }
      await lines.cancel();
      expect(event, contains('message 3'));

      expect(
        (await get(
          '/log-viewer/api/files?file=daravel-2026-10-28.log',
          method: 'DELETE',
        )).$1,
        204,
      );
      expect(file.existsSync(), isFalse);
    });

    test('closed outside local without middleware; options off', () async {
      app = await boot(
        env: {
          'APP_ENV': 'production',
          'APP_KEY': 'base64:${base64Encode(List.filled(32, 7))}',
        },
      );
      expect((await get('/log-viewer')).$1, 403);
      await app.shutdown();
      app = await boot(
        env: {
          'APP_ENV': 'production',
          'APP_KEY': 'base64:${base64Encode(List.filled(32, 7))}',
          'LOG_VIEWER_ALLOW_DOWNLOAD': 'false',
        },
        middleware: ['allow'],
      );
      File(p.join(logs, 'daravel-2026-10-28.log'))
          .writeAsStringSync('${jsonLine(1)}\n');
      expect((await get('/log-viewer')).$1, 200);
      expect((await get('/log-viewer/api/download')).$1, 403);
      expect(
        (await get(
          '/log-viewer/api/files?file=daravel-2026-10-28.log',
          method: 'DELETE',
        )).$1,
        403,
      );
      await app.shutdown();
      app = await boot(env: {'LOG_VIEWER_ENABLED': 'false'});
      expect((await get('/log-viewer')).$1, 404);
    });
  });
}

final class _Allow implements Middleware {
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}
