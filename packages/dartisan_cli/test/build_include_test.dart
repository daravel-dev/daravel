import 'dart:io';

import 'package:dartisan_cli/src/project_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String bundle;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_include');
    bundle = p.join(root.path, 'build', 'server', 'bundle');
  });
  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String content) {
    final file = File(p.join(root.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  bool inBundle(String path) => File(p.join(bundle, path)).existsSync();

  test('directories and files are copied at the same relative path', () {
    write('public/css/app.css', 'body{}');
    write('public/index.html', '<p>');
    write('redis/lua/score.lua', 'return 1');
    write('database/schema.sql', 'select 1;');

    final includes = ['public', 'redis/lua', 'database/schema.sql'];
    expect(bundleIncludeErrors(root.path, includes), isEmpty);
    expect(copyBundleIncludes(root.path, bundle, includes), 4);
    expect(inBundle('public/css/app.css'), isTrue);
    expect(inBundle('public/index.html'), isTrue);
    expect(inBundle('redis/lua/score.lua'), isTrue);
    expect(inBundle('database/schema.sql'), isTrue);
  });

  test('a directory replaces the copy of an earlier build', () {
    write('public/old.js', 'old');
    copyBundleIncludes(root.path, bundle, ['public']);
    File(p.join(root.path, 'public', 'old.js')).deleteSync();
    write('public/new.js', 'new');

    copyBundleIncludes(root.path, bundle, ['public']);
    expect(inBundle('public/old.js'), isFalse);
    expect(inBundle('public/new.js'), isTrue);
  });

  test('.env files inside an included directory are skipped', () {
    write('config/app.json', '{}');
    write('config/.env', 'APP_KEY=secret');
    write('config/.env.production', 'APP_KEY=secret');
    write('config/.envrc.sample', 'kept: not an .env file');

    expect(copyBundleIncludes(root.path, bundle, ['config']), 2);
    expect(inBundle('config/app.json'), isTrue);
    expect(inBundle('config/.envrc.sample'), isTrue);
    expect(inBundle('config/.env'), isFalse);
    expect(inBundle('config/.env.production'), isFalse);
  });

  test('paths outside the project, secrets and the bundle own are refused', () {
    write('.env', 'APP_KEY=secret');
    write('.env.production', 'APP_KEY=secret');
    final absolute = p.join(root.path, 'public');
    final errors = bundleIncludeErrors(root.path, [
      absolute,
      '../elsewhere',
      'public/../..',
      '.',
      '.env',
      '.env.production',
      'lib',
      'bin/server',
      'missing',
    ]);
    expect(errors, hasLength(9));
    expect(errors[0], contains('relative to the project'));
    expect(errors[1], contains('inside the project'));
    expect(errors[2], contains('inside the project'));
    expect(errors[3], contains('inside the project'));
    expect(errors[4], contains('secrets'));
    expect(errors[5], contains('secrets'));
    expect(errors[6], contains('belong to the built bundle'));
    expect(errors[7], contains('belong to the built bundle'));
    expect(errors[8], contains('not found'));
  });

  test('a project with public/ is reminded when it is left out', () {
    expect(bundleIncludeHint(root.path, const []), isNull);
    write('public/index.html', '<p>');
    expect(
      bundleIncludeHint(root.path, const []),
      contains('--include public'),
    );
    expect(bundleIncludeHint(root.path, const ['database']), isNotNull);
    expect(bundleIncludeHint(root.path, const ['public']), isNull);
    expect(bundleIncludeHint(root.path, const ['public/css']), isNull);
  });
}
