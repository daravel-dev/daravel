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
            'LOG_LEVEL': 'warning',
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

    Future<Response> post(Object? body, {List<int>? bytes}) => app.handle(
      Request.fake(
        method: 'POST',
        path: '/payments/webhook/midtrans',
        headers: {'content-type': 'application/json'},
        body: bytes == null ? jsonEncode(body) : String.fromCharCodes(bytes),
      ),
    );
    var statusCalls = 0;
    // Midtrans' status API as the fake answers it: [answer] as JSON, a 500
    // when null, or [raw] as the body.
    Future<void> statusApi(
      Map<String, Object?>? answer, {
      String? raw,
      int code = 200,
    }) => app.run(() async {
      statusCalls = 0;
      Http.fake({
        'app.sandbox.midtrans.com/*': Http.response({
          'token': 'snap-token',
          'redirect_url': 'https://app.sandbox.midtrans.com/snap/v4/x',
        }, 201),
        'api.sandbox.midtrans.com/*': (ClientRequest request) {
          statusCalls++;
          if (raw != null) {
            return Http.response(raw, code);
          }
          return answer == null
              ? Http.response({'status_message': 'down'}, 500)
              : Http.response(answer, code);
        },
      });
    });
    Map<String, Object?> apiAnswer(
      String status, {
      String orderId = 'ORDER-42',
      String transactionId = 'tx-1',
      String? fraud,
    }) => {
      'status_code': '200',
      'transaction_status': status,
      'transaction_id': transactionId,
      'order_id': orderId,
      'gross_amount': '150000.00',
      'currency': 'IDR',
      'payment_type': 'credit_card',
      'fraud_status': ?fraud,
    };

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
      // A challenge is confirmed with the status API.
      await statusApi(apiAnswer('capture', fraud: 'challenge'));
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

    test('Midtrans event ids hold the signed order, the transaction, the '
        'status and the fraud status', () async {
      final gateway = MidtransGateway(serverKey: serverKey);
      Http.fake({
        'api.sandbox.midtrans.com/*': Http.response(
          apiAnswer('capture', fraud: 'challenge'),
        ),
      });
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
      expect(challenge.eventId, 'ORDER-42:tx-1:capture:challenge');
      expect(accept.eventId, 'ORDER-42:tx-1:capture:accept');
      final settled = await gateway.parseWebhook(
        Request.fake(
          method: 'POST',
          path: '/x',
          body: jsonEncode(notification()),
        ),
      );
      expect(settled.eventId, 'ORDER-42:tx-1:settlement');
    });

    // The signature covers status_code, not transaction_status.
    test('a settlement signed under another code than a payment\'s is '
        'confirmed with the status API, not taken', () async {
      await order();
      await statusApi(apiAnswer('pending'));
      final forged = notification(status: 'settlement', statusCode: '201');
      final response = await post(forged);
      expect(response.status, 200);
      expect(await response.bodyText(), '{"status":"unchanged"}');
      expect(await status(), PaymentStatus.pending);
      expect(statusCalls, 1);
    });

    // A paid event from a built-in gateway carries its amount.
    test('a paid Midtrans notification whose amount cannot be read is '
        'refused (400) and logged as a warning without its payload', () async {
      await order();
      final logs = await app.run(() async => Log.spy());
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
      final warned = logs.matching(
        LogLevel.warning,
        'Payment notification refused',
      );
      expect(warned, hasLength(1));
      expect(Map.of(warned.single.context)..remove('request_id'), {
        'gateway': 'midtrans',
        'event_id': 'ORDER-42:tx-1:settlement',
        'order_id': 'ORDER-42',
      });
      expect(
        '${warned.single.message} ${warned.single.context}',
        isNot(contains('signature')),
      );
    });

    // Only a payment is taken from the notification itself; every other
    // status comes from Midtrans' status API.
    group('Midtrans statuses', () {
      Future<int> logRows() => app.run(
        () async =>
            (await DB.table(PaymentManager.webhookLogTable).get()).length,
      );

      test('official expire and cancel notifications (202) apply once the '
          'status API confirms them', () async {
        await order();
        await statusApi(apiAnswer('expire'));
        expect(
          await notify(notification(status: 'expire', statusCode: '202')),
          PaymentOutcome.applied.name,
        );
        expect(await status(), PaymentStatus.expired);
        await app.run(
          () => Payment.checkout(
            const PaymentRequest(orderId: 'ORDER-43', amount: 150000),
          ),
        );
        await statusApi(apiAnswer('cancel', orderId: 'ORDER-43'));
        expect(
          await notify(
            notification(
              orderId: 'ORDER-43',
              status: 'cancel',
              statusCode: '202',
            ),
          ),
          PaymentOutcome.applied.name,
        );
        expect(await status('ORDER-43'), PaymentStatus.failed);
      });

      test('a status_code sent as a number reads as the text', () async {
        await order();
        final body = notification()..['status_code'] = 200;
        // Signed over "200" either way.
        expect(await notify(body), PaymentOutcome.applied.name);
        expect(await status(), PaymentStatus.paid);
      });

      test(
        'a refund is taken from the status API, not the notification',
        () async {
          await order();
          expect(await notify(notification()), PaymentOutcome.applied.name);
          await statusApi(apiAnswer('settlement'));
          for (final code in ['201', '200']) {
            final refund = notification(status: 'refund', statusCode: code);
            final response = await post(refund);
            expect(response.status, 200, reason: code);
            expect(await status(), PaymentStatus.paid, reason: code);
          }
          await statusApi(apiAnswer('refund'));
          final confirmed = notification(
            status: 'refund',
            statusCode: '200',
            grossAmount: '150000.00',
          )..['transaction_id'] = 'tx-2';
          confirmed['signature_key'] = MidtransGateway(serverKey: serverKey)
              .signatureFor(confirmed);
          // The same signature as the refund above: within the window the
          // earlier answer is reused, after it the API is asked again.
          expect((await post(confirmed)).status, 200);
          expect(await status(), PaymentStatus.paid);
          expect(statusCalls, 0);
          Clock.travel(
            MidtransGateway.confirmationWindow + const Duration(seconds: 1),
          );
          addTearDown(Clock.restore);
          expect((await post(confirmed)).status, 200);
          expect(await status(), PaymentStatus.refunded);
          expect(statusCalls, 1);
        },
      );

      test('a confirmed event takes its id from the status the API answered: '
          'a forged refund does not swallow the real one', () async {
        await order();
        Future<String> answer(Map<String, Object?> body) async =>
            (jsonDecode(await (await post(body)).bodyText())
                    as Map<String, Object?>)['status']!
                as String;
        // A signed pending notification turned into a refund; the API says
        // settlement, so the payment is paid under ORDER-42:tx-1:settlement.
        await statusApi(apiAnswer('settlement'));
        final forged = notification(status: 'refund', statusCode: '201');
        expect(await answer(forged), PaymentOutcome.applied.name);
        expect(await status(), PaymentStatus.paid);
        // The genuine settlement notification is then a duplicate.
        expect(await answer(notification()), PaymentOutcome.duplicate.name);
        // The real refund later: the API says refund, a new event.
        await statusApi(apiAnswer('refund'));
        final refund = notification(status: 'refund', statusCode: '200');
        expect(await answer(refund), PaymentOutcome.applied.name);
        expect(await status(), PaymentStatus.refunded);
        // And its retry is a duplicate.
        expect(await answer(refund), PaymentOutcome.duplicate.name);
      });

      test('a status API that fails answers 5xx and changes nothing', () async {
        await order();
        await statusApi(null);
        final rows = await logRows();
        final response = await post(
          notification(status: 'deny', statusCode: '202'),
        );
        expect(response.status, greaterThanOrEqualTo(500));
        expect(await status(), PaymentStatus.pending);
        expect(await logRows(), rows, reason: 'no log row');
        expect(statusCalls, 1, reason: 'the status API was asked');
      });

      test(
        'settlement with a fraud status other than accept is not paid',
        () async {
          await order();
          await statusApi(apiAnswer('settlement', fraud: 'deny'));
          expect(
            await notify(notification(fraud: 'deny')),
            PaymentOutcome.applied.name,
          );
          expect(await status(), PaymentStatus.failed);
          await app.run(
            () => Payment.checkout(
              const PaymentRequest(orderId: 'ORDER-43', amount: 150000),
            ),
          );
          await statusApi(
            apiAnswer('settlement', orderId: 'ORDER-43', fraud: 'challenge'),
          );
          await notify(notification(orderId: 'ORDER-43', fraud: 'challenge'));
          expect(await status('ORDER-43'), PaymentStatus.pending);
        },
      );

      test('bodies that are not an object answer 401, not 500', () async {
        for (final body in [<Object?>[], 123, null, 'text']) {
          expect((await post(body)).status, 401, reason: '$body');
        }
      });

      test('a signed amount of NaN or Infinity answers 400', () async {
        await order();
        for (final amount in ['NaN', 'Infinity']) {
          final response = await post(notification(grossAmount: amount));
          expect(response.status, 400, reason: amount);
        }
        expect(await status(), PaymentStatus.pending);
      });
    });

    // Midtrans signs order_id, status_code and gross_amount only.
    group('fields Midtrans does not sign', () {
      Future<void> orderOf(String orderId) => app.run(
        () =>
            Payment.checkout(PaymentRequest(orderId: orderId, amount: 150000)),
      );
      Future<String> outcome(Map<String, Object?> body) async {
        final response = await post(body);
        expect(response.status, lessThan(500));
        return (jsonDecode(await response.bodyText())
                as Map<String, Object?>)['status']!
            as String;
      }

      test('an event of one order is never taken for another\'s', () async {
        await order();
        await orderOf('ORDER-A');
        await orderOf('ORDER-B');
        // Its own signed payment, under the victim's transaction id.
        final own = notification(orderId: 'ORDER-A')
          ..['transaction_id'] = 'tx-victim';
        expect(await outcome(own), PaymentOutcome.applied.name);
        // Its own signed pending turned into a failure, which the status
        // API answers for its own order with the victim's transaction id.
        await statusApi(
          apiAnswer(
            'settlement',
            orderId: 'ORDER-B',
            transactionId: 'tx-victim',
          ),
        );
        final turned = notification(
          orderId: 'ORDER-B',
          status: 'failure',
          statusCode: '201',
        )..['transaction_id'] = 'tx-victim';
        expect(await outcome(turned), PaymentOutcome.applied.name);
        // Or the victim's order id as the transaction id.
        final named = notification(orderId: 'ORDER-A', status: 'settlement')
          ..['transaction_id'] = 'ORDER-42';
        expect(await outcome(named), isNot(PaymentOutcome.applied.name));
        // The victim's genuine payment still applies.
        final genuine = notification()..['transaction_id'] = 'tx-victim';
        expect(await outcome(genuine), PaymentOutcome.applied.name);
        expect(await status(), PaymentStatus.paid);
      });

      test('expire and cancel, both signed 202, are told apart by the '
          'status API', () async {
        await order();
        await statusApi(apiAnswer('expire'));
        // The expiry's signed notification, made a cancellation.
        final swapped = notification(status: 'cancel', statusCode: '202');
        expect(await outcome(swapped), PaymentOutcome.applied.name);
        expect(await status(), PaymentStatus.expired);
        final genuine = notification(status: 'expire', statusCode: '202');
        expect(await outcome(genuine), PaymentOutcome.duplicate.name);
      });

      test(
        'a deny slipped into a challenged capture does not fail it',
        () async {
          await order();
          await statusApi(apiAnswer('capture', fraud: 'challenge'));
          final denied = notification(
            status: 'capture',
            statusCode: '201',
            fraud: 'deny',
          );
          expect(await outcome(denied), PaymentOutcome.unchanged.name);
          expect(await status(), PaymentStatus.pending);
        },
      );

      test(
        'a field of the wrong type, or no transaction id, answers 400',
        () async {
          await order();
          for (final (key, value) in <(String, Object?)>[
            ('transaction_id', 12345),
            ('transaction_id', ''),
            ('transaction_id', '  '),
            ('transaction_id', null),
            ('transaction_status', 123),
            ('fraud_status', 123),
            ('currency', 123),
            ('payment_type', 123),
            ('transaction_time', 123),
            ('settlement_time', <Object?>[]),
          ]) {
            final body = notification()..[key] = value;
            if (value == null) {
              body.remove(key);
            }
            expect((await post(body)).status, 400, reason: '$key $value');
          }
          expect(await status(), PaymentStatus.pending);
        },
      );

      test('a status API answer about another order, or without JSON, '
          'applies nothing', () async {
        await order();
        final failure = notification(status: 'failure', statusCode: '201');
        await statusApi(apiAnswer('settlement', orderId: 'ORDER-999'));
        expect((await post(failure)).status, greaterThanOrEqualTo(500));
        for (final code in [502, 200]) {
          await statusApi(null, raw: '<html>Bad Gateway</html>', code: code);
          expect((await post(failure)).status, greaterThanOrEqualTo(500));
          await expectLater(
            app.run(
              () => Payment.manager.gateway('midtrans').status('ORDER-42'),
            ),
            throwsA(isA<PaymentGatewayException>()),
            reason: '$code',
          );
        }
        expect(await status(), PaymentStatus.pending);
        // Midtrans' "404" for an order not paid yet: nothing changes.
        await statusApi({'status_code': '404', 'status_message': 'none'});
        expect(await outcome(failure), PaymentOutcome.unchanged.name);
        expect(await status(), PaymentStatus.pending);
      });

      test('one signed notification posted again and again asks the status '
          'API once per window', () async {
        await order();
        await statusApi(apiAnswer('pending'));
        final signedPending = notification(
          status: 'failure',
          statusCode: '201',
        );
        for (var i = 0; i < 10; i++) {
          await outcome(signedPending);
        }
        expect(statusCalls, 1);
        // Made-up statuses are one kind: one more call in all.
        for (var i = 0; i < 5; i++) {
          await outcome(notification(status: 'made-up-$i', statusCode: '201'));
        }
        expect(statusCalls, 2);
        // On a paid order, a refund posted five times: one call.
        expect(await outcome(notification()), PaymentOutcome.applied.name);
        await statusApi(apiAnswer('settlement'));
        for (var i = 0; i < 5; i++) {
          await outcome(notification(status: 'refund', statusCode: '200'));
        }
        expect(statusCalls, 1);
        expect(await status(), PaymentStatus.paid);
      });

      test('statuses Midtrans may sign under other codes are confirmed, not '
          'refused', () async {
        await order();
        await statusApi(apiAnswer('expire'));
        expect(
          await outcome(notification(status: 'expire', statusCode: '407')),
          PaymentOutcome.applied.name,
        );
        expect(await status(), PaymentStatus.expired);
        await orderOf('ORDER-43');
        await statusApi(apiAnswer('cancel', orderId: 'ORDER-43'));
        expect(
          await outcome(notification(orderId: 'ORDER-43', status: 'cancel')),
          PaymentOutcome.applied.name,
        );
        expect(await status('ORDER-43'), PaymentStatus.failed);
        await orderOf('ORDER-44');
        await statusApi(
          apiAnswer('capture', orderId: 'ORDER-44', fraud: 'challenge'),
        );
        expect(
          await outcome(
            notification(
              orderId: 'ORDER-44',
              status: 'capture',
              statusCode: '201',
              fraud: 'challenge',
            ),
          ),
          PaymentOutcome.unchanged.name,
        );
        expect(await status('ORDER-44'), PaymentStatus.pending);
      });

      test('a notification logged under an earlier event id is a new event '
          'after upgrading, which changes nothing already applied', () async {
        await order();
        final now = DateTime.utc(2026, 11, 14);
        await app.run(() async {
          // As an earlier version logged and applied it.
          await DB.table(PaymentManager.webhookLogTable).insert({
            'gateway': 'midtrans',
            'event_id': 'tx-1:settlement',
            'order_id': 'ORDER-42',
            'payload': '{}',
            'processed': true,
            'created_at': now,
            'updated_at': now,
          });
          await DB
              .table(PaymentManager.transactionsTable)
              .where('order_id', 'ORDER-42')
              .update({'status': 'paid', 'paid_at': now, 'updated_at': now});
        });
        expect(await outcome(notification()), PaymentOutcome.unchanged.name);
        expect(await status(), PaymentStatus.paid);
        expect(events.whereType<PaymentPaid>(), isEmpty);
      });
    });
  });

  // The answer to an order not stored yet.
  test('unknownOrderStatus outside 200 to 599 is refused when the route '
      'is registered', () {
    for (final status in [0, 199, 600, -1]) {
      expect(
        () => Payment.webhookRoutes(Router(), unknownOrderStatus: status),
        throwsArgumentError,
        reason: '$status',
      );
    }
    Payment.webhookRoutes(Router(), unknownOrderStatus: 503);
  });

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

  group('a paid event without its amount or currency', () {
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

  // A body that is not UTF-8, sent as raw bytes through a real
  // server (Request.fake would encode it), never reaches a 500.
  test('a body that is not UTF-8 is refused as unsigned (401)', () async {
    Future<Object?> parse(
      PaymentGateway gateway,
      List<int> bytes,
      Map<String, String> headers,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Object? failure = 'parsed';
      final handled = server.first.then((httpRequest) async {
        try {
          await gateway.parseWebhook(
            Request.fromHttpRequest(httpRequest, id: 'raw'),
          );
        } on Object catch (error) {
          failure = error;
        }
        await httpRequest.response.close();
      });
      final client = HttpClient();
      final request = await client.post('127.0.0.1', server.port, '/');
      headers.forEach(request.headers.set);
      request.add(bytes);
      await (await request.close()).drain<void>();
      await handled;
      client.close();
      await server.close();
      return failure;
    }

    const malformed = [0x7B, 0x22, 0x61, 0xC3, 0x28, 0x22, 0x7D];
    expect(
      await parse(MidtransGateway(serverKey: serverKey), malformed, const {}),
      isA<InvalidPaymentSignatureException>(),
    );
    final t = Clock.now().millisecondsSinceEpoch ~/ 1000;
    expect(
      await parse(
        StripeGateway(secretKey: 'sk_test_1', webhookSecret: 'whsec_test'),
        malformed,
        {'stripe-signature': 't=$t,v1=${'0' * 64}'},
      ),
      isA<InvalidPaymentSignatureException>(),
    );
  });
}
