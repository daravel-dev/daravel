@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// DB-1 (Reviewer RSEQ 49 #4b): `DB_SSLROOTCERT` reaches the PostgreSQL
/// connection, as Laravel's `PostgresConnector` passes `sslrootcert` to
/// libpq. Runs when `DARAVEL_TEST_PG_TLS` (a server with TLS whose
/// certificate a throwaway CA signed for `localhost` only) and
/// `DARAVEL_TEST_PG_TLS_CA` (that CA's PEM file) are set; CI's PostgreSQL
/// job makes both (`.github/workflows/ci.yml`).
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG_TLS'];
  final ca = Platform.environment['DARAVEL_TEST_PG_TLS_CA'];
  if (url == null || url.isEmpty || ca == null || ca.isEmpty) {
    test(
      'postgres TLS (skipped: DARAVEL_TEST_PG_TLS or _CA not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);

  PostgresDriver driver(
    Map<String, Object?> options, {
    String? host,
    List<String>? warnings,
  }) => PostgresDriver.fromConfig(
    'tls',
    ConnectionConfig(
      driver: 'pgsql',
      database: uri.path.replaceFirst('/', ''),
      host: host ?? uri.host,
      port: uri.port,
      username: uri.userInfo.split(':').first,
      password: Uri.decodeComponent(uri.userInfo.split(':')[1]),
      options: {'pool': 1, ...options},
    ),
    onWarning: (warnings ?? <String>[]).add,
  );

  Future<bool> encrypted(PostgresDriver db) async {
    await db.connect();
    addTearDown(db.close);
    final rows = await db.select(
      'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()',
    );
    return rows.single['ssl'] == true;
  }

  test('verify-full with DB_SSLROOTCERT connects, encrypted', () async {
    expect(
      await encrypted(driver({'sslmode': 'verify-full', 'sslrootcert': ca})),
      isTrue,
    );
  });

  test('verify-full without the CA refuses the server', () async {
    final db = driver({'sslmode': 'verify-full'});
    addTearDown(db.close);
    await expectLater(db.connect(), throwsA(anything));
  });

  test('verify-full with the CA refuses a host the certificate does not '
      'name', () async {
    final db = driver({
      'sslmode': 'verify-full',
      'sslrootcert': ca,
    }, host: '127.0.0.1');
    addTearDown(db.close);
    await expectLater(db.connect(), throwsA(anything));
  });

  // libpq checks the chain for require + a CA; this driver cannot, so the
  // pair is refused rather than connecting unchecked (a .env from Laravel).
  test('require with DB_SSLROOTCERT is refused when the driver is made, '
      'naming both ways out', () {
    expect(
      () => driver({'sslmode': 'require', 'sslrootcert': ca}),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('verify-full'), contains('remove DB_SSLROOTCERT')),
        ),
      ),
    );
  });

  test('require without a CA connects, encrypted and unchecked', () async {
    expect(await encrypted(driver({'sslmode': 'require'})), isTrue);
  });
}
