import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Architecture rules for this application (`dartisan lint` runs the same).
void main() {
  test('passes every Daravel lint rule', expectLintClean);

  test('keeps no mutable static state in lib/app', expectNoMutableStatics);

  test(
    'registers every migration, seeder, job and command',
    expectRegistryComplete,
  );

  test('controllers go through DB/models, never raw drivers', () {
    expectNoImports('lib/app/http/controllers', [
      RegExp(r'^package:(sqlite3|postgres)/'),
    ]);
  });
}
