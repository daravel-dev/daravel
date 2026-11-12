import 'dart:io';

import 'package:daravel/daravel.dart';

/// The `createApp` of a project's `bootstrap/app.dart`, as `dartisan new`
/// writes it, which [bootTestApp] takes as it is.
typedef TestAppFactory = Application Function({
  String? basePath,
  Map<String, String>? env,
});

/// The environment of a test application, with [overrides] applied last:
///
/// - `APP_ENV=testing`
/// - `DB_CONNECTION=sqlite`
/// - `DB_URL=sqlite::memory:`, a fresh in-memory database per application
///
/// ```dart
/// final app = createApp(env: testEnv({'APP_NAME': 'Starter'}));
/// ```
Map<String, String> testEnv([
  Map<String, String> overrides = const <String, String>{},
]) => <String, String>{
  'APP_ENV': 'testing',
  'DB_CONNECTION': 'sqlite',
  'DB_URL': 'sqlite::memory:',
  ...overrides,
};

/// Creates the application [create] makes, with [testEnv] plus [env] and
/// [basePath] (the current directory unless given: `dart test` runs from
/// the package root), and boots it.
///
/// Shutting it down is the test's own step, so it reads where the test
/// starts it:
///
/// ```dart
/// setUp(() async {
///   app = await bootTestApp(createApp, env: {'APP_NAME': 'Starter'});
///   client = TestClient(app);
/// });
/// tearDown(() => app.shutdown());
/// ```
///
/// For a database that is migrated once per file and rolled back after
/// each test, use `refreshDatabase(() => createApp(basePath:
/// Directory.current.path, env: testEnv()))` instead.
Future<Application> bootTestApp(
  TestAppFactory create, {
  Map<String, String> env = const <String, String>{},
  String? basePath,
}) async {
  final app = create(
    basePath: basePath ?? Directory.current.path,
    env: testEnv(env),
  );
  await app.boot();
  return app;
}
