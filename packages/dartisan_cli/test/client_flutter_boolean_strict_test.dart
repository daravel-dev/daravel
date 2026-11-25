import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:dartisan_cli/src/client_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `boolean:strict` accepts only `true` and `false` on the server, so the
/// generated client must not let `1`, `'1'` or `'true'` through its own
/// pre-check, while plain `boolean` stays as lenient as the server's.
void main() {
  group('generator', () {
    late String inputs;

    setUpAll(() async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) {
              r
                  .post('/flags', (_) async => Response.json(const {}))
                  .name('flags.update')
                  .rules({'lenient': 'boolean', 'strict': 'boolean:strict'});
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      inputs = generateClient(
        routesUnder(app.router.routes, '/api'),
        packageName: 'app_client',
        baseUrl: 'http://127.0.0.1:8000',
      ).files['lib/src/inputs.dart']!;
    });

    test('plain boolean keeps the lenient check', () {
      expect(
        inputs,
        contains(
          "'lenient': FieldChecks([Check.type('boolean', "
          "'The lenient field must be true or false.')",
        ),
      );
    });

    test('boolean:strict gets the strict check with the same message', () {
      expect(
        inputs,
        contains(
          "'strict': FieldChecks([Check.type('boolean_strict', "
          "'The strict field must be true or false.')",
        ),
      );
    });
  });

  group('runtime', () {
    late Map<String, Object?> results;

    // Values as JSON literals: the runtime sees them as Dart values.
    const values = <String>[
      'true',
      'false',
      '1',
      '0',
      "'1'",
      "'0'",
      "'true'",
      "'false'",
      '1.0',
      '0.0',
    ];

    setUpAll(() async {
      final source = clientRuntimeSource;
      final start = source.indexOf('/// One server validation rule');
      expect(start, greaterThan(0));
      final dir = Directory.systemTemp.createTempSync('bool_strict');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File(p.join(dir.path, 'main.dart'))
        ..writeAsStringSync('''
import 'dart:convert';

${source.substring(start)}

void main() {
  const lenient = Check.type('boolean', 'no');
  const strict = Check.type('boolean_strict', 'no');
  final values = <Object?>[${values.join(', ')}];
  String? run(Check check, Object? v) {
    try {
      return check.apply(v, const {});
    } on Object {
      return 'crash';
    }
  }
  print(jsonEncode({
    'lenient': [for (final v in values) run(lenient, v)],
    'strict': [for (final v in values) run(strict, v)],
  }));
}
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        script.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      results = (jsonDecode('${result.stdout}'.trim()) as Map)
          .cast<String, Object?>();
    });

    test('strict passes only true and false', () {
      expect(results['strict'], [
        null,
        null,
        'no',
        'no',
        'no',
        'no',
        'no',
        'no',
        'no',
        'no',
      ]);
    });

    test('lenient is unchanged for the same values', () {
      expect(results['lenient'], [
        null, // true
        null, // false
        null, // 1
        null, // 0
        null, // '1'
        null, // '0'
        null, // 'true'
        null, // 'false'
        null, // 1.0 (== 1 in Dart)
        null, // 0.0
      ]);
    });
  });
}
