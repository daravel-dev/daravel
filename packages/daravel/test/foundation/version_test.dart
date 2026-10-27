import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `daravelVersion` is the single source of the release number; every
/// workspace package carries the same version.
void main() {
  test('every workspace pubspec matches daravelVersion', () {
    final root = p.normalize(p.join(Directory.current.path, '..', '..'));
    for (final package in [
      'packages/daravel',
      'packages/daravel_lints',
      'packages/daravel_test',
      'packages/dartisan_cli',
      'packages/daravel_mysql',
      'packages/daravel_permission',
      'packages/daravel_redis',
      'packages/daravel_teorion',
      'packages/daravel_livekit',
      'packages/daravel_s3',
      'packages/daravel_sqlite',
      'packages/daravel_postgres',
      'apps/daravel_starter',
      'bench',
    ]) {
      final pubspec = File(p.join(root, package, 'pubspec.yaml'))
          .readAsStringSync();
      final version = RegExp(
        r'^version: (.+)$',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1);
      expect(version, daravelVersion, reason: package);
    }
  });

  test('published packages carry the root LICENSE and a changelog entry', () {
    final root = p.normalize(p.join(Directory.current.path, '..', '..'));
    final license = File(p.join(root, 'LICENSE')).readAsStringSync();
    for (final package in [
      'daravel',
      'daravel_lints',
      'daravel_test',
      'dartisan_cli',
    ]) {
      final dir = p.join(root, 'packages', package);
      expect(
        File(p.join(dir, 'LICENSE')).readAsStringSync(),
        license,
        reason: '$package/LICENSE must equal the root LICENSE',
      );
      expect(
        File(p.join(dir, 'CHANGELOG.md')).readAsStringSync(),
        contains('## $daravelVersion'),
        reason: '$package/CHANGELOG.md',
      );
      expect(File(p.join(dir, 'README.md')).existsSync(), isTrue);
      expect(File(p.join(dir, 'example', 'main.dart')).existsSync(), isTrue);
      expect(
        File(p.join(dir, 'pubspec.yaml')).readAsStringSync(),
        isNot(contains('publish_to: none')),
      );
    }
  });
}
