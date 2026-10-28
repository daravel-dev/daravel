import 'dart:io';

import 'package:dartisan_cli/src/project_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dartisan_nosqlite'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String content) {
    final file = File(p.join(root.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String path) => File(p.join(root.path, path)).readAsStringSync();

  test('a standalone project gets the hooks only during the build', () {
    const pubspec = 'name: app\nenvironment:\n  sdk: ^3.13.0\n';
    write('app/pubspec.yaml', pubspec);
    final appRoot = p.join(root.path, 'app');
    expect(hooksPubspec(appRoot).path, p.join(appRoot, 'pubspec.yaml'));

    final restore = useSystemSqlite(appRoot);
    expect(read('app/pubspec.yaml'), contains('      source: system'));
    expect(read('app/pubspec.yaml'), startsWith(pubspec.trimRight()));
    restore();
    expect(read('app/pubspec.yaml'), pubspec, reason: 'restored exactly');
  });

  test('a workspace member writes the workspace root pubspec', () {
    write('pubspec.yaml', 'name: ws\nworkspace:\n  - apps/api\n');
    write('apps/api/pubspec.yaml', 'name: api\nresolution: workspace\n');
    final member = p.join(root.path, 'apps', 'api');
    expect(
      p.normalize(hooksPubspec(member).path),
      p.normalize(p.join(root.path, 'pubspec.yaml')),
    );
    final restore = useSystemSqlite(member);
    expect(read('pubspec.yaml'), contains('source: system'));
    expect(read('apps/api/pubspec.yaml'), isNot(contains('hooks')));
    restore();
    expect(read('pubspec.yaml'), 'name: ws\nworkspace:\n  - apps/api\n');
  });

  test('an existing hooks section is used or refused, never merged', () {
    write('a/pubspec.yaml', 'name: a\n$systemSqliteHooks');
    expect(systemSqliteConfigured(p.join(root.path, 'a')), isTrue);
    final already = read('a/pubspec.yaml');
    useSystemSqlite(p.join(root.path, 'a'))();
    expect(read('a/pubspec.yaml'), already);

    write(
      'b/pubspec.yaml',
      'name: b\nhooks:\n  user_defines:\n    other: {x: 1}\n',
    );
    expect(
      () => useSystemSqlite(p.join(root.path, 'b')),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('yourself'),
        ),
      ),
    );
  });

  test('leftover SQLite libraries are removed from the bundle', () {
    write('bundle/lib/sqlite3.dll', 'x');
    write('bundle/lib/libsqlite3.so', 'x');
    write('bundle/lib/other.dll', 'x');
    removeBundledSqlite(p.join(root.path, 'bundle'));
    expect(
      Directory(p.join(root.path, 'bundle', 'lib'))
          .listSync()
          .map((f) => p.basename(f.path)),
      ['other.dll'],
    );
  });

  test('DB_CONNECTION comes from the environment, then .env', () {
    write('app/.env', 'APP_NAME=x\nDB_CONNECTION="pgsql" # production\n');
    final appRoot = p.join(root.path, 'app');
    final expected = Platform.environment['DB_CONNECTION'];
    expect(
      projectEnvValue(appRoot, 'DB_CONNECTION'),
      expected != null && expected.isNotEmpty ? expected : 'pgsql',
    );
    expect(projectEnvValue(appRoot, 'MISSING_KEY'), isNull);
  });
  test('the Dockerfile leaves SQLite out for other databases', () {
    final plain = dockerfileTemplate();
    final lean = dockerfileTemplate(sqlite: false);
    expect(plain, isNot(contains('source: system')));
    expect(lean, contains("grep -q '^hooks:' pubspec.yaml || printf"));
    expect(lean, contains(r'sqlite3:\n      source: system'));
    expect(
      lean,
      contains('# bin/server and bin/dartisan (no bundled libraries).'),
    );
    // The build stage still builds both executables.
    expect(
      'dart build cli'.allMatches(lean).length,
      'dart build cli'.allMatches(plain).length,
    );
  });

  test('the distroless Dockerfile needs no shell at run time', () {
    final image = dockerfileTemplate(distroless: true);
    final runtime = image.substring(image.lastIndexOf('\nFROM '));
    expect(runtime, startsWith('\nFROM gcr.io/distroless/cc-debian12:nonroot'));
    // Nothing runs in the runtime stage: it has no shell.
    expect(runtime, isNot(contains('\nRUN ')));
    expect(runtime, contains('USER nonroot'));
    expect(
      runtime,
      contains('COPY --from=build --chown=65532:65532 /runtime/ ./'),
    );
    expect(image, contains('mkdir -p /runtime/storage/logs'));
    final lean = dockerfileTemplate(sqlite: false, distroless: true);
    expect(lean, contains(r'sqlite3:\n      source: system'));
    expect(lean, contains('FROM gcr.io/distroless/cc-debian12:nonroot'));
  });
}
