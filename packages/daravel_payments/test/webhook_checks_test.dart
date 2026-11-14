import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_payments/daravel_payments.dart';
import 'package:test/test.dart';

const serverKey = 'SB-Mid-server-TEST';

/// A Midtrans HTTP notification for ORDER-42, signed with [serverKey].
Map<String, Object?> notification({
  String orderId = 'ORDER-42',
  String status = 'settlement',
  String statusCode = '200',
  String grossAmount = '150000.00',
  String? currency,
  String? fraud,
}) {
  final body = <String, Object?>{
    'order_id': orderId,
    'status_code': statusCode,
    'gross_amount': grossAmount,
    'transaction_status': status,
    'transaction_id': 'tx-1',
    'payment_type': 'credit_card',
    'transaction_time': '2026-10-29 15:00:00',
    'currency': ?currency,
    'fraud_status': ?fraud,
  };
  body['signature_key'] = MidtransGateway(serverKey: serverKey)
      .signatureFor(body);
  return body;
}

void main() {
  group('gateway secrets', () {
    test('an empty or blank secret is refused when the gateway is made', () {
      for (final blank in ['', ' ', '\t\n']) {
        expect(
          () => MidtransGateway(serverKey: blank),
          throwsArgumentError,
          reason: 'Midtrans serverKey "$blank"',
        );
        expect(
          () => StripeGateway(secretKey: 'sk_test_1', webhookSecret: blank),
          throwsArgumentError,
          reason: 'Stripe webhookSecret "$blank"',
        );
        expect(
          () => StripeGateway(secretKey: blank, webhookSecret: 'whsec_1'),
          throwsArgumentError,
          reason: 'Stripe secretKey "$blank"',
        );
        expect(
          () => XenditGateway(secretKey: 'xnd_dev', callbackToken: blank),
          throwsArgumentError,
          reason: 'Xendit callbackToken "$blank"',
        );
        expect(
          () => XenditGateway(secretKey: blank, callbackToken: 'tok'),
          throwsArgumentError,
          reason: 'Xendit secretKey "$blank"',
        );
      }
    });

    test('a blank key in .env counts as no key', () {
      final config = PaymentsConfig.fromEnv(
        Env.fromMap({
          'MIDTRANS_SERVER_KEY': '  ',
          'XENDIT_SECRET_KEY': 'xnd_dev',
          'XENDIT_WEBHOOK_TOKEN': ' ',
          'STRIPE_SECRET': 'sk_test_1',
          'STRIPE_WEBHOOK_SECRET': '\t',
        }),
      );
      expect(config.midtransServerKey, isNull);
      expect(config.xenditWebhookToken, isNull);
      expect(config.stripeWebhookSecret, isNull);
      final manager = PaymentManager(config);
      for (final name in ['midtrans', 'xendit', 'stripe']) {
        expect(() => manager.gateway(name), throwsA(isA<ConfigException>()));
      }
    });
  });

  group('webhooks', () {
    late Directory dir;
    late Application app;
    late List<Object> events;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('daravel_payments_checks_');
      events = [];
      app = Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': '${dir.path}/app.sqlite',
            'LOG_LEVEL': 'error',
            'MIDTRANS_SERVER_KEY': serverKey,
          })
          .withPayments()
          .withMigrations(const [CreatePaymentTables()])
          .withEvents((e) {
            e
              ..listen<PaymentPaid>(events.add)
              ..listen<PaymentAmountMismatch>(events.add);
          })
          .create();
      await app.boot();
      await app.run(() async {
        await App.make<Migrator>().run();
        Http.fake({
          'app.sandbox.midtrans.com/*': Http.response({
            'token': 'snap-token',
            'redirect_url':
                'https://app.sandbox.midtrans.com/snap/v4/redirection/x',
          }, 201),
        });
      });
    });
    tearDown(() async {
      await app.shutdown();
      Container.setRoot(null);
      dir.deleteSync(recursive: true);
    });

    Future<void> order() => app.run(
      () => Payment.checkout(
        const PaymentRequest(orderId: 'ORDER-42', amount: 150000),
      ),
    );

    Future<String> notify(Map<String, Object?> body) async {
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/payments/webhook/midtrans',
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        ),
      );
      final status =
          (jsonDecode(await response.bodyText())
                  as Map<String, Object?>)['status']!
              as String;
      expect(
        response.status,
        status == PaymentOutcome.unknownOrder.name ? 409 : 200,
        reason: status,
      );
      return status;
    }

    Future<PaymentStatus?> status([String orderId = 'ORDER-42']) async =>
        (await app.run<PaymentRecord?>(() => Payment.find(orderId)))?.status;

    test('a signed amount in another currency never pays', () async {
      await order();
      expect(
        await notify(notification(currency: 'USD')),
        PaymentOutcome.amountMismatch.name,
      );
      expect(await status(), PaymentStatus.pending);
      expect(events.single, isA<PaymentAmountMismatch>());
      // The same notification in the order's currency (any case) pays.
      expect(
        await notify(notification(currency: 'idr')),
        PaymentOutcome.applied.name,
      );
      expect(await status(), PaymentStatus.paid);
    });

    test('an event in another currency than a USD order never pays', () async {
      final now = DateTime.utc(2026, 11, 14);
      await app.run(
        () => DB.table(PaymentManager.transactionsTable).insert({
          'order_id': 'ORDER-USD',
          'gateway': 'stripe',
          'amount': 100,
          'currency': 'USD',
          'status': 'pending',
          'created_at': now,
          'updated_at': now,
        }),
      );
      final outcome = await app.run(
        () => Payment.manager.apply(
          const PaymentEvent(
            gateway: 'stripe',
            eventId: 'evt_1',
            orderId: 'ORDER-USD',
            status: PaymentStatus.paid,
            amount: 100,
            currency: 'IDR',
          ),
        ),
      );
      expect(outcome, PaymentOutcome.amountMismatch);
      expect(await status('ORDER-USD'), PaymentStatus.pending);
    });

    test(
      'a notification that came before its order applies on retry',
      () async {
        final paid = notification();
        expect(await notify(paid), PaymentOutcome.unknownOrder.name);
        await order();
        expect(await notify(paid), PaymentOutcome.applied.name);
        expect(await status(), PaymentStatus.paid);
        expect(events.whereType<PaymentPaid>(), hasLength(1));
        // Once applied, the same notification is a duplicate.
        expect(await notify(paid), PaymentOutcome.duplicate.name);
        expect(events.whereType<PaymentPaid>(), hasLength(1));
      },
    );

    test('an unchanged or mismatched notification is not recorded as '
        'handled', () async {
      await order();
      final pending = notification(status: 'pending', statusCode: '201');
      expect(await notify(pending), PaymentOutcome.unchanged.name);
      expect(await notify(pending), PaymentOutcome.unchanged.name);
      final short = notification(grossAmount: '1500.00');
      expect(await notify(short), PaymentOutcome.amountMismatch.name);
      expect(await notify(short), PaymentOutcome.amountMismatch.name);
    });

    test(
      'a unique violation without this event\'s log row is no duplicate',
      () async {
        // That happens when the delivery that wrote the clashing row rolled
        // back; it cannot be timed on a real database, so a unique index of
        // the test's own on order_id makes the insert clash with another
        // event's row.
        await order();
        final now = DateTime.utc(2026, 11, 14);
        await app.run(() async {
          await (await Schema.builder()).table(
            PaymentManager.webhookLogTable,
            (table) =>
                table.unique(['order_id'], name: 'test_one_log_per_order'),
          );
          await DB.table(PaymentManager.webhookLogTable).insert({
            'gateway': 'midtrans',
            'event_id': 'another-event',
            'order_id': 'ORDER-42',
            'payload': '{}',
            'processed': true,
            'created_at': now,
            'updated_at': now,
          });
        });
        final response = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/payments/webhook/midtrans',
            headers: {'content-type': 'application/json'},
            body: jsonEncode(notification()),
          ),
        );
        expect(response.status, 500, reason: 'the gateway sends it again');
        expect(await status(), PaymentStatus.pending);
        expect(events.whereType<PaymentPaid>(), isEmpty);
      },
    );

    test('a card challenged, then accepted, is paid', () async {
      await order();
      expect(
        await notify(notification(status: 'capture', fraud: 'challenge')),
        PaymentOutcome.unchanged.name,
      );
      expect(await status(), PaymentStatus.pending);
      expect(
        await notify(notification(status: 'capture', fraud: 'accept')),
        PaymentOutcome.applied.name,
      );
      expect(await status(), PaymentStatus.paid);
    });

    test('Midtrans event ids include the fraud status', () async {
      final gateway = MidtransGateway(serverKey: serverKey);
      final challenge = await gateway.parseWebhook(
        Request.fake(
          method: 'POST',
          path: '/x',
          body: jsonEncode(notification(status: 'capture', fraud: 'challenge')),
        ),
      );
      final accept = await gateway.parseWebhook(
        Request.fake(
          method: 'POST',
          path: '/x',
          body: jsonEncode(notification(status: 'capture', fraud: 'accept')),
        ),
      );
      expect(challenge.eventId, isNot(accept.eventId));
      expect(accept.eventId, 'tx-1:capture:accept');
      final settled = await gateway.parseWebhook(
        Request.fake(
          method: 'POST',
          path: '/x',
          body: jsonEncode(notification()),
        ),
      );
      expect(settled.eventId, 'tx-1:settlement');
    });

    // RSEQ 64 C: the signature covers status_code, not transaction_status.
    test('a Midtrans status that disagrees with its signed code is refused '
        '(401) and changes nothing', () async {
      await order();
      final forged = notification(status: 'settlement', statusCode: '201');
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/payments/webhook/midtrans',
          headers: {'content-type': 'application/json'},
          body: jsonEncode(forged),
        ),
      );
      expect(response.status, 401);
      expect(await status(), PaymentStatus.pending);
    });

    // RSEQ 64 B: a paid event from a built-in gateway carries its amount.
    test('a paid Midtrans notification whose amount cannot be read is '
        'refused (400)', () async {
      await order();
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/payments/webhook/midtrans',
          headers: {'content-type': 'application/json'},
          body: jsonEncode(notification(grossAmount: 'many')),
        ),
      );
      expect(response.status, 400);
      expect(await status(), PaymentStatus.pending);
    });
  });

  // RSEQ 64 A: the answer to an order not stored yet.
  test('unknownOrderStatus: 200 restores the earlier answer', () async {
    final dir = Directory.systemTemp.createTempSync('daravel_payments_a_');
    final app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': '${dir.path}/app.sqlite',
          'LOG_LEVEL': 'error',
          'MIDTRANS_SERVER_KEY': serverKey,
        })
        .withPayments(unknownOrderStatus: 200)
        .withMigrations(const [CreatePaymentTables()])
        .create();
    await app.boot();
    addTearDown(() async {
      await app.shutdown();
      Container.setRoot(null);
      dir.deleteSync(recursive: true);
    });
    await app.run(() => App.make<Migrator>().run());
    final response = await app.handle(
      Request.fake(
        method: 'POST',
        path: '/payments/webhook/midtrans',
        headers: {'content-type': 'application/json'},
        body: jsonEncode(notification()),
      ),
    );
    expect(response.status, 200);
    expect(await response.bodyText(), '{"status":"unknownOrder"}');
  });

  group('a paid event without its amount or currency (RSEQ 64 B)', () {
    Request post(String body, {Map<String, String> headers = const {}}) =>
        Request.fake(method: 'POST', path: '/x', headers: headers, body: body);

    test('Stripe: a completed session without its currency', () async {
      const secret = 'whsec_test';
      final stripe = StripeGateway(
        secretKey: 'sk_test_1',
        webhookSecret: secret,
      );
      final payload = jsonEncode({
        'id': 'evt_1',
        'type': 'checkout.session.completed',
        'data': {
          'object': {
            'id': 'cs_1',
            'client_reference_id': 'ORDER-1',
            'payment_status': 'paid',
            'amount_total': 1999,
          },
        },
      });
      final t = Clock.now().millisecondsSinceEpoch ~/ 1000;
      final header = 't=$t,v1=${hmacSha256Hex(secret, '$t.$payload')}';
      await expectLater(
        stripe.parseWebhook(
          post(payload, headers: {'stripe-signature': header}),
        ),
        throwsA(isA<BadRequestHttpException>()),
      );
    });

    test('Xendit: a paid invoice without its amount or currency', () async {
      final xendit = XenditGateway(secretKey: 'xnd_dev', callbackToken: 'tok');
      for (final invoice in [
        {'id': 'inv-1', 'external_id': 'ORDER-9', 'status': 'PAID'},
        {
          'id': 'inv-1',
          'external_id': 'ORDER-9',
          'status': 'PAID',
          'paid_amount': 50000,
        },
      ]) {
        await expectLater(
          xendit.parseWebhook(
            post(jsonEncode(invoice), headers: {'x-callback-token': 'tok'}),
          ),
          throwsA(isA<BadRequestHttpException>()),
          reason: '$invoice',
        );
      }
    });
  });
}
