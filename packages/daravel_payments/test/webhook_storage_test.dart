import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:daravel_payments/daravel_payments.dart';
import 'package:test/test.dart';

final class _EventGateway implements PaymentGateway {
  _EventGateway(this.event);
  final PaymentEvent event;
  @override
  String get name => 'fixture';
  @override
  Future<PaymentEvent> parseWebhook(Request request) async => event;
  @override
  Future<PaymentEvent> status(String orderId, {String? reference}) async =>
      event;
  @override
  Future<PaymentCheckout> create(PaymentRequest request) async =>
      PaymentCheckout(
        gateway: name,
        orderId: request.orderId,
        reference: request.orderId,
        redirectUrl: 'https://example.test/pay',
      );
}

Map<String, String> _mysqlEnv(String url) {
  final uri = Uri.parse(url);
  final credentials = uri.userInfo.split(':');
  return {
    'DB_CONNECTION': 'mysql',
    'DB_HOST': uri.host,
    'DB_PORT': '${uri.hasPort ? uri.port : 3306}',
    'DB_DATABASE': uri.pathSegments.first,
    'DB_USERNAME': credentials.first,
    'DB_PASSWORD': credentials.length > 1 ? credentials[1] : '',
  };
}

void main() {
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  final mysql = Platform.environment['DARAVEL_TEST_MYSQL'];
  final runs = <String, Map<String, String>?>{
    'SQLite': {'DB_DATABASE': ':memory:'},
    'PostgreSQL': pg == null || pg.isEmpty
        ? null
        : {'DB_CONNECTION': 'pgsql', 'DB_URL': pg},
    'MySQL': mysql == null || mysql.isEmpty ? null : _mysqlEnv(mysql),
  };
  for (final MapEntry(key: name, value: env) in runs.entries) {
    group(name, () {
      late Application app;
      setUp(() async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({'APP_ENV': 'testing', ...env!})
            .withLogLevel(LogLevel.critical)
            .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
            .withPayments()
            .create();
        await app.boot();
        await app.run(() async {
          final schema = await Schema.builder();
          await const CreatePaymentTables().down(schema);
          await const CreatePaymentTables().up(schema);
        });
      });
      tearDown(() async {
        await app.run(
          () async => const CreatePaymentTables().down(await Schema.builder()),
        );
        await app.shutdown();
        Container.setRoot(null);
      });

      Future<void> order(String orderId) =>
          DB.table(PaymentManager.transactionsTable).insert({
            'gateway': 'fixture',
            'order_id': orderId,
            'amount': 100,
            'currency': 'IDR',
            'status': 'pending',
            'created_at': DateTime.utc(2026),
            'updated_at': DateTime.utc(2026),
          });

      PaymentEvent event({
        String orderId = 'order',
        String eventId = 'event',
        Map<String, Object?> raw = const {},
      }) => PaymentEvent(
        gateway: 'fixture',
        eventId: eventId,
        orderId: orderId,
        status: PaymentStatus.paid,
        amount: 100,
        currency: 'IDR',
        raw: raw,
      );

      for (final bytes in [65535, 65536, 1 << 20]) {
        test(
          'log payload uses a byte budget of 65535 ($bytes)',
          () => app.run(() async {
            await order('order');
            final raw = <String, Object?>{'text': 'a' * (bytes - 11)};
            expect(utf8.encode(jsonEncode(raw)), hasLength(bytes));
            expect(
              await Payment.manager.apply(event(raw: raw)),
              PaymentOutcome.applied,
            );
            final row = (await DB
                .table(PaymentManager.webhookLogTable)
                .first())!;
            final stored = row['payload']! as String;
            expect(utf8.encode(stored).length, lessThanOrEqualTo(65535));
            expect(
              jsonDecode(stored),
              bytes <= 65535 ? raw : {'truncated': true, 'bytes': bytes},
            );
          }),
        );
      }

      test(
        'a later delivery updates the stored payload within its byte budget',
        () => app.run(() async {
          final raw = <String, Object?>{'text': 'a' * 65536};
          expect(
            await Payment.manager.apply(event()),
            PaymentOutcome.unknownOrder,
          );
          await order('order');
          expect(
            await Payment.manager.apply(event(raw: raw)),
            PaymentOutcome.applied,
          );
          final row = (await DB.table(PaymentManager.webhookLogTable).first())!;
          final stored =
              jsonDecode(row['payload']! as String) as Map<String, Object?>;
          expect(stored['truncated'], isTrue);
          expect(stored['bytes'], utf8.encode(jsonEncode(raw)).length);
        }),
      );

      for (final field in ['order', 'event']) {
        for (final character in ['a', '😀']) {
          test(
            '$field identifiers use at most 255 Unicode characters ($character)',
            () => app.run(() async {
              final value = character * 255;
              final valid = event(
                orderId: field == 'order' ? value : 'order',
                eventId: field == 'event' ? value : 'event',
              );
              await order(valid.orderId);
              expect(
                await Payment.manager.apply(valid),
                PaymentOutcome.applied,
              );
              final row = (await DB
                  .table(PaymentManager.webhookLogTable)
                  .first())!;
              expect(row['order_id'], valid.orderId);
              expect(row['event_id'], valid.eventId);
              final invalid = event(
                orderId: field == 'order' ? '$value$character' : 'order',
                eventId: field == 'event' ? '$value$character' : 'event',
              );
              final before = await DB
                  .table(PaymentManager.webhookLogTable)
                  .count();
              await expectLater(
                Future.sync(() => Payment.manager.apply(invalid)),
                throwsArgumentError,
              );
              Payment.manager.register(_EventGateway(invalid));
              await expectLater(
                Payment.manager.handleWebhook('fixture', Request.fake()),
                throwsA(isA<BadRequestHttpException>()),
              );
              expect(
                await DB.table(PaymentManager.webhookLogTable).count(),
                before,
              );
            }),
          );
        }
      }
      for (final field in ['order', 'event']) {
        test(
          '$field identifiers are checked before webhook storage',
          () => app.run(() async {
            final invalid = event(
              orderId: field == 'order' ? 'a' * 256 : 'order',
              eventId: field == 'event' ? 'a' * 256 : 'event',
            );
            Payment.manager.register(_EventGateway(invalid));
            await expectLater(
              Payment.manager.handleWebhook('fixture', Request.fake()),
              throwsA(isA<BadRequestHttpException>()),
            );
            expect(await DB.table(PaymentManager.webhookLogTable).count(), 0);
          }),
        );
      }
    }, skip: env == null ? '$name URL not set' : false);
  }
}
