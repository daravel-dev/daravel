import 'dart:io';

import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Production settings for the generated project's tests; SQLite in memory
/// as the queue Horizon reads.
const String _production = '''
const production = <String, String>{
  'APP_ENV': 'production',
  'APP_DEBUG': 'false',
  'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  'HORIZON_ALLOW_SQLITE': 'true',
  'SESSION_DRIVER': 'array',
};
''';

/// Without sessions: a guest is refused, HorizonDashboard.auth decides.
const String _withoutSessions =
    '''
import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

$_production
void main() {
  Application? app;

  tearDown(() async {
    HorizonDashboard.auth(null);
    await app?.shutdown();
  });

  test('a guest is refused the dashboard and its mutations', () async {
    final booted = app = await bootTestApp(createApp, env: production);
    final client = TestClient(booted);
    (await client.get('/horizon')).assertForbidden();
    (await client.post('/horizon/api/jobs/retry-all')).assertForbidden();
  });

  test('HorizonDashboard.auth opens it', () async {
    const key = 'e2e-secret';
    HorizonDashboard.auth(
      (request) => constantTimeEquals(request.header('x-horizon-key') ?? '', key),
    );
    final booted = app = await bootTestApp(createApp, env: production);
    final client = TestClient(booted);
    (await client.get('/horizon/api/stats')).assertForbidden();
    (await client.get(
      '/horizon/api/stats',
      headers: {'x-horizon-key': key},
    )).assertOk();
  });
}
''';

/// With sessions: the viewHorizon gate lets a signed-in user in.
const String _withSessions =
    '''
import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:shop/app/models/user.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

$_production
void main() {
  Application? app;

  tearDown(() async => app?.shutdown());

  test('the viewHorizon gate lets a signed-in user in', () async {
    final booted = app = await bootTestApp(createApp, env: production);
    await booted.run(() => App.make<Migrator>().run());
    final ops = await booted.run(
      () => User.definition.query().create({
        'name': 'Ops',
        'email': 'ops@example.com',
        'password': 'not-used',
      }),
    );
    await booted.run(
      () async => Gate.define(
        'viewHorizon',
        (Authenticatable? user, _) =>
            user?.authIdentifier == ops.authIdentifier,
      ),
    );
    // As a browser: the session and its XSRF cookie come back, so the
    // mutation below passes CSRF and meets the gate.
    final client = TestClient(booted, cookieJar: CookieJar());
    (await client.get('/horizon')).assertForbidden();
    (await client.post('/horizon/api/jobs/retry-all')).assertForbidden();
    (await client.actingAs(ops).get('/horizon')).assertOk();
    (await client.actingAs(ops).get('/horizon/api/stats')).assertOk();
  });
}
''';

void main() {
  test(
    'pub:add horizon in a new project: closed outside local, opened by '
    'HorizonDashboard.auth or, with sessions, by the gate (e2e)',
    () async {
      final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
      final root = await Directory.systemTemp.createTemp(
        'horizon_install_e2e_',
      );
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold a file.
        }
      });
      final target = p.join(root.path, 'shop');
      expect(
        await GlobalDartisanRunner().execute(['new', target, '--path=$repo']),
        0,
      );
      Future<int?> dartisan(List<String> args) => IOOverrides.runZoned(
        () => DartisanRunner(() => throw StateError('not booted')).run(args),
        getCurrentDirectory: () => Directory(target),
      );
      final pubspec = File(p.join(target, 'pubspec.yaml'));
      String local(String package) =>
          p.join(repo, 'packages', package).replaceAll(r'\', '/');
      // The unpublished package from this checkout instead of pub.dev.
      void fromCheckout(String package) => pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          '  $package: ^$daravelVersion',
          '  $package: {path: ${local(package)}}',
        ),
      );
      Future<ProcessResult> dart(List<String> args) =>
          Process.run(dartExecutable(), args, workingDirectory: target);
      Future<void> getAnalyzeTest() async {
        final get = await dart(['pub', 'get']);
        expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
        await dart(['format', 'bootstrap', 'test']);
        final analyze = await dart(['analyze', '--fatal-infos']);
        expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
        final test = await dart(['test']);
        expect(test.exitCode, 0, reason: '${test.stdout}${test.stderr}');
      }

      // Without sessions: the installer's snippet boots as it is.
      expect(await dartisan(['pub:add', 'horizon', '--no-get']), 0);
      fromCheckout('daravel_horizon');
      File(p.join(target, 'test', 'feature', 'horizon_test.dart'))
          .writeAsStringSync(_withoutSessions);
      await getAnalyzeTest();

      // With sessions: the same snippet, behind the web group now; the
      // guest checks above were for the application without them.
      File(p.join(target, 'test', 'feature', 'horizon_test.dart')).deleteSync();
      expect(await dartisan(['pub:add', 'session', '--no-get']), 0);
      fromCheckout('daravel_session');
      File(p.join(target, 'test', 'feature', 'horizon_session_test.dart'))
          .writeAsStringSync(_withSessions);
      await getAnalyzeTest();
    },
    skip: Platform.environment['DARAVEL_E2E'] == '1'
        ? false
        : 'set DARAVEL_E2E=1 to run (new + pub:add horizon and session + '
              'analyze + test)',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
