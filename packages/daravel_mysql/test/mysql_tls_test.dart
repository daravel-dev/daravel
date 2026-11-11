@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// TLS against a server whose certificate a test CA signed for `localhost`
/// only. Runs when `DARAVEL_TEST_MYSQL_TLS` (the server, reached as
/// `localhost`) and `DARAVEL_TEST_MYSQL_TLS_CA` (the CA's PEM file) are set;
/// CI's MySQL job makes both (`.github/workflows/ci.yml`).
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL_TLS'];
  final ca = Platform.environment['DARAVEL_TEST_MYSQL_TLS_CA'];
  if (url == null || url.isEmpty || ca == null || ca.isEmpty) {
    test(
      'mysql TLS (skipped: DARAVEL_TEST_MYSQL_TLS or _CA not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');

  /// Opens a pool with [options] on [host], runs `SELECT 1`, closes it.
  Future<void> probe(Map<String, Object?> options, {String? host}) async {
    final driver = MySqlDriver.fromConfig(
      'mysql',
      ConnectionConfig(
        driver: 'mysql',
        database: uri.path.replaceFirst('/', ''),
        host: host ?? uri.host,
        port: uri.port,
        username: user.first,
        password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
        options: {'pool': 1, 'connect_timeout': '10', ...options},
      ),
    );
    try {
      await driver.connect();
      final rows = await driver.select('SELECT 1 AS one');
      expect(rows.single['one'], 1);
    } finally {
      await driver.close();
    }
  }

  test(
    'verify-full with the CA connects (certificate and host name)',
    () async {
      await probe({'sslmode': 'verify-full', 'sslrootcert': ca});
    },
  );

  test(
    'a CA alone (MYSQL_ATTR_SSL_CA, no mode) verifies and connects',
    () async {
      await probe({'sslrootcert': ca});
    },
  );

  test(
    'verify-full without the CA refuses the server before logging in',
    () async {
      await expectLater(
        probe({'sslmode': 'verify-full'}),
        throwsA(isA<HandshakeException>()),
      );
    },
  );

  test(
    'verify-full refuses a host name the certificate does not name',
    () async {
      await expectLater(
        probe({'sslmode': 'verify-full', 'sslrootcert': ca}, host: '127.0.0.1'),
        throwsA(isA<HandshakeException>()),
      );
    },
  );

  test('require still connects without checking (no CA)', () async {
    await probe({'sslmode': 'require'});
  });
}
