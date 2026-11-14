import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:daravel_payments/daravel_payments.dart';
import 'package:test/test.dart';

/// `DARAVEL_TEST_PG=postgres://user:secret@127.0.0.1:5432/db` and
/// `DARAVEL_TEST_MYSQL=mysql://user:secret@127.0.0.1:3306/db` run these
/// against a real server, as the core's suites do. They drop and create
/// the payment tables.
final String? pgUrl = Platform.environment['DARAVEL_TEST_PG'];
final String? mysqlUrl = Platform.environment['DARAVEL_TEST_MYSQL'];

const serverKey = 'SB-Mid-server-TEST';
const rounds = 20;

Map<String, String> mysqlEnv(String url) {
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  return {
    'DB_CONNECTION': 'mysql',
    'DB_HOST': uri.host,
    'DB_PORT': '${uri.hasPort ? uri.port : 3306}',
    'DB_DATABASE': uri.pathSegments.isEmpty ? '' : uri.pathSegments.first,
    'DB_USERNAME': user.first,
    'DB_PASSWORD': user.length > 1 ? user[1] : '',
  };
}

Map<String, Object?> notification(String orderId) {
  final body = <String, Object?>{
    'order_id': orderId,
    'status_code': '200',
    'gross_amount': '150000.00',
    'transaction_status': 'settlement',
    'transaction_id': 'tx-$orderId',
    'payment_type': 'qris',
    'transaction_time': '2026-10-29 15:00:00',
    'currency': 'IDR',
  };
  body['signature_key'] = MidtransGateway(serverKey: serverKey)
      .signatureFor(body);
  return body;
}

void main() {
  final runs = <String, (String?, Map<String, String> Function(String))>{
    'PostgreSQL': (pgUrl, (url) => {'DB_CONNECTION': 'pgsql', 'DB_URL': url}),
    'MySQL': (mysqlUrl, mysqlEnv),
  };

  for (final MapEntry(key: name, value: (url, env)) in runs.entries) {
    group('two deliveries of one event at once, $name', () {
      late Application app;
      late List<PaymentPaid> paid;

      setUp(() async {
        paid = [];
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({
              'APP_ENV': 'testing',
              'MIDTRANS_SERVER_KEY': serverKey,
              ...env(url!),
            })
            .withLogLevel(LogLevel.critical)
            .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
            .withPayments()
            .withEvents((e) => e.listen<PaymentPaid>(paid.add))
            .create();
        await app.boot();
        await app.run(() async {
          final schema = await Schema.builder();
          await const CreatePaymentTables().down(schema);
          await const CreatePaymentTables().up(schema);
        });
      });
      tearDown(() async {
        await app.run(() async {
          await const CreatePaymentTables().down(await Schema.builder());
        });
        await app.shutdown();
        Container.setRoot(null);
      });

      Future<void> order(String orderId) => app.run(() async {
        final now = DateTime.utc(2026, 11, 14);
        await DB.table(PaymentManager.transactionsTable).insert({
          'order_id': orderId,
          'gateway': 'midtrans',
          'amount': 150000,
          'currency': 'IDR',
          'status': 'pending',
          'created_at': now,
          'updated_at': now,
        });
      });

      Future<(int, String)> deliver(Map<String, Object?> body) async {
        final response = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/payments/webhook/midtrans',
            headers: {'content-type': 'application/json'},
            body: jsonEncode(body),
          ),
        );
        final text = await response.bodyText();
        if (response.status != 200 && response.status != 409) {
          return (response.status, text);
        }
        final json = jsonDecode(text) as Map<String, Object?>;
        return (response.status, json['status']! as String);
      }

      Future<void> expectOneApplied(String orderId) async {
        final body = notification(orderId);
        final results = await Future.wait([deliver(body), deliver(body)]);
        expect(results.map((r) => r.$2).toList()..sort(), [
          'applied',
          'duplicate',
        ], reason: '$orderId: $results');
        final row = await app.run(() => Payment.find(orderId));
        expect(row!.status, PaymentStatus.paid);
      }

      test('a new event: one applied, one duplicate', () async {
        for (var i = 0; i < rounds; i++) {
          await order('NEW-$i');
          await expectOneApplied('NEW-$i');
        }
        expect(paid, hasLength(rounds));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('an event seen before its order, then retried twice at once: one '
          'applied, one duplicate', () async {
        for (var i = 0; i < rounds; i++) {
          expect(await deliver(notification('LATE-$i')), (409, 'unknownOrder'));
          await order('LATE-$i');
          await expectOneApplied('LATE-$i');
        }
        expect(paid, hasLength(rounds));
      }, timeout: const Timeout(Duration(minutes: 2)));
    }, skip: url == null || url.isEmpty ? '$name URL not set' : false);
  }
}
