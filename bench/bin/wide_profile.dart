import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';

/// Where the time of scenario 13 (1 000 rows x 40 columns) goes, in one
/// isolate, without HTTP:
///
/// ```bash
/// dart run bin/bench.dart --database=mariadb://... --scenarios=13   # seeds
/// dart run bin/wide_profile.dart --database=mariadb://db:db@127.0.0.1:3306/daravel_bench
/// ```
///
/// Prints the mean milliseconds of: the query with one column (transport
/// and the server), the full query (adds row decoding), `Response.json`
/// encoding, and the `json_encode` rewrite (`phpCompatible: true`).
Future<void> main(List<String> args) async {
  final url = args
      .where((a) => a.startsWith('--database='))
      .map((a) => a.substring('--database='.length))
      .firstOrNull;
  final rounds = int.parse(
    args
            .where((a) => a.startsWith('--rounds='))
            .map((a) => a.substring('--rounds='.length))
            .firstOrNull ??
        '30',
  );
  final base = Directory.systemTemp.createTempSync('daravel_wide_profile');
  final app = Application.configure(basePath: base.path)
      .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
      .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
      .withEnv({
        'APP_ENV': 'local',
        'LOG_LEVEL': 'error',
        if (url != null) 'DB_URL': url else 'DB_DATABASE': 'build/bench.sqlite',
      })
      .create();
  await app.boot();
  try {
    await app.run(() async {
      Future<double> time(Future<Object?> Function() body) async {
        for (var i = 0; i < 3; i++) {
          await body();
        }
        final watch = Stopwatch()..start();
        for (var i = 0; i < rounds; i++) {
          await body();
        }
        return watch.elapsedMicroseconds / rounds / 1000;
      }

      final rows = await DB.table('wide_rows').orderBy('id').get();
      final json = Response.encodeJson(rows);
      final report = {
        'rows': rows.length,
        'columns': rows.isEmpty ? 0 : rows.first.length,
        'json_bytes': utf8.encode(json).length,
        'query_id_only_ms': await time(
          () => DB.table('wide_rows').orderBy('id').select(['id']).get(),
        ),
        'query_all_columns_ms': await time(
          () => DB.table('wide_rows').orderBy('id').get(),
        ),
        // Four at once on the pool: about the single time means waiting
        // (server, network), about four times means work in this isolate.
        'query_all_columns_x4_concurrent_ms': await time(
          () => Future.wait([
            for (var i = 0; i < 4; i++)
              DB.table('wide_rows').orderBy('id').get(),
          ]),
        ),
        'encode_json_ms': await time(() async => Response.encodeJson(rows)),
        'php_rewrite_ms': await time(
          () async => phpJsonFromDart(json, emptyMapsAsArrays: true),
        ),
        'php_rewrite_per_char_ms': await time(() async => _perCharacter(json)),
      };
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    });
  } finally {
    await app.shutdown();
    base.deleteSync(recursive: true);
  }
}

/// The per-character rewrite `phpJsonEncode` used before 1.18, kept to show
/// what the one-pass version saves.
String _perCharacter(String json) {
  final out = StringBuffer();
  for (final unit in json.codeUnits) {
    if (unit == 0x2F) {
      out.write(r'\/');
    } else if (unit > 0x7F) {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}
