import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// A `createApp` as `dartisan new` writes it, recording what it was given.
Map<String, String>? givenEnv;
String? givenBasePath;

Application createApp({String? basePath, Map<String, String>? env}) {
  givenEnv = env;
  givenBasePath = basePath;
  return Application.configure(basePath: basePath ?? Directory.current.path)
      .withEnv(env ?? const <String, String>{})
      .withLogLevel(LogLevel.critical)
      .create();
}

void main() {
  test('testEnv: testing, SQLite in memory, overrides last', () {
    expect(testEnv(), {
      'APP_ENV': 'testing',
      'DB_CONNECTION': 'sqlite',
      'DB_URL': 'sqlite::memory:',
    });
    expect(testEnv({'APP_NAME': 'Starter', 'DB_URL': 'sqlite:x.db'}), {
      'APP_ENV': 'testing',
      'DB_CONNECTION': 'sqlite',
      'DB_URL': 'sqlite:x.db',
      'APP_NAME': 'Starter',
    });
  });

  test('a createApp of the generated shape is a TestAppFactory', () {
    const TestAppFactory factory = createApp;
    expect(factory, isNotNull);
  });

  group('bootTestApp', () {
    late Application app;
    tearDown(() => app.shutdown());

    test('boots with testEnv and the current directory', () async {
      app = await bootTestApp(createApp, env: {'APP_NAME': 'Starter'});
      expect(givenBasePath, Directory.current.path);
      expect(givenEnv, testEnv({'APP_NAME': 'Starter'}));
      expect(app.env.maybeString('APP_ENV'), 'testing');
      expect(app.env.maybeString('APP_NAME'), 'Starter');
      expect(app.env.maybeString('DB_URL'), 'sqlite::memory:');
    });

    test('takes another base path', () async {
      final dir = Directory.systemTemp.createTempSync('boot_test_app_');
      addTearDown(() => dir.deleteSync(recursive: true));
      app = await bootTestApp(createApp, basePath: dir.path);
      expect(givenBasePath, dir.path);
      expect(app.basePath, dir.path);
    });
  });
}
