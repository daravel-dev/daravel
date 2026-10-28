import 'dart:io';
import 'dart:isolate';

import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every claim of the registry against the packages' source, so `pub:add`
/// never writes a key, a builder call or a migration a package does not
/// have.
Future<void> main() async {
  // From the package's location, not the working directory, which other
  // tests of the run change.
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:dartisan_cli/dartisan_cli.dart'),
  );
  final packages = p.normalize(
    p.join(p.dirname(library!.toFilePath()), '..', '..'),
  );

  String source(String package) => [
    for (final file
        in Directory(p.join(packages, package, 'lib'))
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')))
      file.readAsStringSync(),
  ].join('\n');

  final core = source('daravel');

  for (final manifest in officialPackages) {
    test(manifest.package, () {
      expect(
        File(p.join(packages, manifest.package, 'pubspec.yaml')).existsSync(),
        isTrue,
        reason: 'a workspace package',
      );
      final code = source(manifest.package);
      for (final call in manifest.registration) {
        final method = RegExp(r'\.(\w+)\(').firstMatch(call)![1]!;
        expect(code, contains('$method('), reason: call);
      }
      for (final line in manifest.env) {
        final key = line.split('=').first;
        expect(
          code.contains("'$key'") || core.contains("'$key'"),
          isTrue,
          reason: '$key is read by ${manifest.package} or the core',
        );
      }
      for (final migration in manifest.migrations) {
        expect(code, contains('class $migration extends Migration'));
      }
      if (manifest.commands case final commands?) {
        expect(
          File(p.join(packages, manifest.package, 'lib', 'commands.dart'))
              .existsSync(),
          isTrue,
        );
        expect(code, contains('List<CommandFactory> $commands'));
      }
      if (manifest.delegate case final delegate?) {
        final runner = DartisanRunner(() => throw StateError('not booted'));
        expect(runner.commands.keys, contains(delegate.first));
      }
    });
  }

  test('every released package is in the registry', () {
    final listed = {for (final m in officialPackages) m.package};
    for (final package in daravelPackages) {
      if (package == 'daravel' || package == 'dartisan_cli') {
        continue;
      }
      expect(listed, contains(package));
    }
  });

  test('names resolve exactly; search tolerates typos', () {
    String one(String name) => resolvePackages(name).single.package;
    expect(one('s3'), 'daravel_s3');
    expect(one('R2'), 'daravel_s3');
    expect(one('bucket'), 'daravel_s3');
    expect(one('rbac'), 'daravel_permission');
    expect(one('roles'), 'daravel_permission');
    expect(one('webrtc'), 'daravel_livekit');
    expect(one('audit'), 'daravel_activitylog');
    expect(one('calendar'), 'daravel_google');
    expect(one('daravel_teorion'), 'daravel_teorion');
    expect(one('pg'), 'daravel_postgres');
    expect(resolvePackages('cloud').map((m) => m.package), [
      'daravel_s3',
      'daravel_google',
    ]);
    expect(
      resolvePackages('permision'),
      isEmpty,
      reason: 'no guessing when installing',
    );
    expect(searchPackages('permision').first.package, 'daravel_permission');
    expect(searchPackages('video').first.package, 'daravel_livekit');
    expect(searchPackages('spreadsheet').first.package, 'daravel_excel');
    expect(searchPackages('blockchain'), isEmpty);
    expect(levenshtein('kitten', 'sitting'), 3);
  });
}
