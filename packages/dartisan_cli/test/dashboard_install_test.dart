import 'dart:io';

import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The generated project's test of one dashboard: production, a guest is
/// refused; the package's auth callback, as the installer suggests it,
/// opens it.
String _dashboardTest({
  required String import,
  required String auth,
  required String path,
  required String header,
  Map<String, String> env = const {},
}) =>
    '''
import 'package:daravel/daravel.dart';
import '$import';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

const production = <String, String>{
  'APP_ENV': 'production',
  'APP_DEBUG': 'false',
  'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
${[for (final MapEntry(:key, :value) in env.entries) "  '$key': '$value',"].join('\n')}
};

void main() {
  Application? app;

  tearDown(() async {
    $auth(null);
    await app?.shutdown();
  });

  test('a guest is refused, with or without middleware', () async {
    final booted = app = await bootTestApp(createApp, env: production);
    (await TestClient(booted).get('$path')).assertForbidden();
  });

  test('APP_ENV=testing is refused too', () async {
    final booted = app = await bootTestApp(
      createApp,
      env: {...production, 'APP_ENV': 'testing'},
    );
    (await TestClient(booted).get('$path')).assertForbidden();
  });

  test('the auth callback opens it', () async {
    const key = 'e2e-secret';
    $auth(
      (request) => constantTimeEquals(request.header('$header') ?? '', key),
    );
    final booted = app = await bootTestApp(createApp, env: production);
    final client = TestClient(booted);
    (await client.get('$path')).assertForbidden();
    (await client.get('$path', headers: {'$header': key})).assertOk();
  });
}
''';

void main() {
  final repo = p.normalize(p.join(Directory.current.path, '..', '..'));

  /// A new project with [package] added, its dashboard test written, and
  /// pub get, analyze and test run on it; [patch] edits the project before.
  Future<void> install(
    String name,
    String package,
    String test, {
    void Function(String target)? patch,
  }) async {
    final root = await Directory.systemTemp.createTemp('${name}_install_e2e_');
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
    final added = await IOOverrides.runZoned(
      () =>
          DartisanRunner(() => throw StateError('not booted'))
              .run(['pub:add', name, '--no-get']),
      getCurrentDirectory: () => Directory(target),
    );
    expect(added, 0);
    final pubspec = File(p.join(target, 'pubspec.yaml'));
    final local = p.join(repo, 'packages', package).replaceAll(r'\', '/');
    pubspec.writeAsStringSync(
      pubspec.readAsStringSync().replaceFirst(
        '  $package: ^$daravelVersion',
        '  $package: {path: $local}',
      ),
    );
    patch?.call(target);
    File(p.join(target, 'test', 'feature', '${name}_dashboard_test.dart'))
        .writeAsStringSync(test);
    Future<ProcessResult> dart(List<String> args) =>
        Process.run(dartExecutable(), args, workingDirectory: target);
    final get = await dart(['pub', 'get']);
    expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
    await dart(['format', 'bootstrap', 'test']);
    final analyze = await dart(['analyze', '--fatal-infos']);
    expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
    final run = await dart(['test']);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
  }

  final skip = Platform.environment['DARAVEL_E2E'] == '1'
      ? false
      : 'set DARAVEL_E2E=1 to run (new + pub:add + analyze + test)';

  test(
    'pub:add pulse in a new project: closed outside local, opened by '
    'Pulse.auth (e2e)',
    () => install(
      'pulse',
      'daravel_pulse',
      _dashboardTest(
        import: 'package:daravel_pulse/daravel_pulse.dart',
        auth: 'Pulse.auth',
        path: '/pulse',
        header: 'x-pulse-key',
      ),
    ),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'pub:add reverb in a new project: closed outside local, opened by '
    'ReverbDashboard.auth (e2e)',
    () => install(
      'reverb',
      'daravel_reverb',
      _dashboardTest(
        import: 'package:daravel_reverb/daravel_reverb.dart',
        auth: 'ReverbDashboard.auth',
        path: '/reverb',
        header: 'x-reverb-key',
        env: {
          'REVERB_APP_ID': '1',
          'REVERB_APP_KEY': 'e2e-key',
          'REVERB_APP_SECRET': 'e2e-secret-of-32-characters-long',
        },
      ),
      // As the installer's next step says: withReverb() needs
      // withBroadcasting().
      patch: (target) {
        final app = File(p.join(target, 'bootstrap', 'app.dart'));
        app.writeAsStringSync(
          app.readAsStringSync().replaceFirst(
            '.withReverb()',
            ".withBroadcasting(authMiddleware: const []).withReverb()",
          ),
        );
      },
    ),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
