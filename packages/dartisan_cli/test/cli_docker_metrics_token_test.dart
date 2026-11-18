import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `build --docker` writes the Dockerfile and `.dockerignore` only where
/// they are new (or with `--force`), and `coordinator:stats` sends the
/// application's `METRICS_TOKEN` on its own only to `APP_URL`'s host or a
/// loopback address.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cli_docker_token');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Application project() => Application.configure(basePath: root.path)
      .withEnv({
        'APP_ENV': 'local',
        'APP_URL': 'https://app.example.test',
        'METRICS_TOKEN': 'metrics-secret',
        'DB_DATABASE': ':memory:',
      })
      .withLogLevel(LogLevel.critical)
      .create();

  Future<int> run(List<String> args) => IOOverrides.runZoned(
    () => DartisanRunner(project).execute(args),
    getCurrentDirectory: () => root,
    stdout: () => _Silent(),
    stderr: () => _Silent(),
  );

  File file(String name) => File(p.join(root.path, name));

  group('build --docker', () {
    test('keeps an existing .dockerignore and writes the Dockerfile', () async {
      file('.dockerignore').writeAsStringSync('.env.production\nsecrets/\n');
      expect(await run(['build', '--docker', '--no-compile']), 0);
      expect(
        file('.dockerignore').readAsStringSync(),
        '.env.production\nsecrets/\n',
      );
      expect(file('Dockerfile').existsSync(), isTrue);
    });

    test('keeps an existing Dockerfile and writes the .dockerignore', () async {
      file('Dockerfile').writeAsStringSync('FROM scratch\n');
      expect(await run(['build', '--docker', '--no-compile']), 0);
      expect(file('Dockerfile').readAsStringSync(), 'FROM scratch\n');
      expect(file('.dockerignore').readAsStringSync(), dockerignoreTemplate);
    });

    test('--force replaces both', () async {
      file('Dockerfile').writeAsStringSync('FROM scratch\n');
      file('.dockerignore').writeAsStringSync('secrets/\n');
      expect(await run(['build', '--docker', '--no-compile', '--force']), 0);
      expect(file('Dockerfile').readAsStringSync(), isNot('FROM scratch\n'));
      expect(file('.dockerignore').readAsStringSync(), dockerignoreTemplate);
    });
  });

  group('coordinator:stats', () {
    test('which hosts get the token without --token', () {
      const app = 'https://app.example.test';
      for (final url in [
        'http://127.0.0.1:8000/metrics',
        'http://127.0.0.9/metrics',
        'http://localhost:8000/metrics',
        'http://LOCALHOST/metrics',
        'http://[::1]:8000/metrics',
        'https://app.example.test/metrics',
        'http://APP.example.test:9000/metrics',
      ]) {
        expect(metricsTokenHostTrusted(url, app), isTrue, reason: url);
      }
      for (final url in [
        'http://evil.example/metrics',
        'https://app.example.test.evil.example/metrics',
        'http://10.0.0.5/metrics',
        'http://127.0.0.1.evil.example/metrics',
        'metrics',
        '',
      ]) {
        expect(metricsTokenHostTrusted(url, app), isFalse, reason: url);
      }
    });

    test(
      'a loopback server gets the token; another host needs --token',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seen = <String?>[];
        server.listen((request) async {
          seen.add(request.headers.value('authorization'));
          request.response.statusCode = 404;
          await request.response.close();
        });
        // 404 is exit 1; what matters is the header that came.
        await run([
          'coordinator:stats',
          '--url=http://127.0.0.1:${server.port}/metrics',
        ]);
        expect(seen, ['Bearer metrics-secret']);
        expect(
          await run(['coordinator:stats', '--url=http://evil.example/metrics']),
          64,
        );
        expect(seen, hasLength(1));
      },
    );

    test('a redirect to another host does not carry the token', () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => other.close(force: true));
      final atOther = <String?>[];
      other.listen((request) async {
        atOther.add(request.headers.value('authorization'));
        request.response.statusCode = 404;
        await request.response.close();
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String?>[];
      server.listen((request) async {
        seen.add(request.headers.value('authorization'));
        request.response
          ..statusCode = 302
          ..headers.set('location', 'http://localhost:${other.port}/metrics');
        await request.response.close();
      });
      await run([
        'coordinator:stats',
        '--url=http://127.0.0.1:${server.port}/metrics',
      ]);
      expect(seen, ['Bearer metrics-secret']);
      // Followed (another host name, the same machine), without the token.
      expect(atOther, [null]);
    });
  });
}

final class _Silent implements Stdout {
  @override
  void write(Object? object) {}

  @override
  void writeln([Object? object = '']) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
