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
}
