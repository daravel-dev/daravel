import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_payments/daravel_payments.dart';
import 'package:test/test.dart';

const serverKey = 'SB-Mid-server-TEST';

/// A Midtrans HTTP notification, signed with [serverKey].
Map<String, Object?> midtransNotification({
  String orderId = 'ORDER-42',
  String status = 'settlement',
  String statusCode = '200',
  String grossAmount = '150000.00',
  String transactionId = 'tx-1',
  String? fraud,
}) {
  final body = <String, Object?>{
    'order_id': orderId,
    'status_code': statusCode,
    'gross_amount': grossAmount,
    'transaction_status': status,
    'transaction_id': transactionId,
    'payment_type': 'qris',
    'transaction_time': '2026-10-29 15:00:00',
    'settlement_time': '2026-10-29 15:01:00',
    'fraud_status': ?fraud,
  };
  body['signature_key'] = MidtransGateway(serverKey: serverKey)
      .signatureFor(body);
  return body;
}

void main() {
  group('signatures', () {
    test('Midtrans: SHA512(order_id+status_code+gross_amount+ServerKey)', () {
      // Computed with `sha512sum`, not with this package.
      expect(
        MidtransGateway(serverKey: serverKey).signatureFor({
          'order_id': 'ORDER-42',
          'status_code': '200',
          'gross_amount': '150000.00',
        }),
        '1d2fc8ccc633ff61f4b09f6c2aabb25b34a8677147c4c301a870188bec7a62b3'
        'b623e0c5a67756e8b2146c447711b6cabfff218a77ae9b28995fd669ffc12b53',
      );
    });

    test('Stripe: v1 = HMAC-SHA256(secret, "t.body"), within tolerance', () {
      final stripe = StripeGateway(
        secretKey: 'sk',
        webhookSecret: 'whsec_test',
      );
      const body = '{"id":"evt_1","type":"checkout.session.completed"}';
      // Computed with `openssl dgst -sha256 -hmac`, not with this package.
      const v1 =
          '749721cbedbfa4cc1aa6c9c2bec1edd93766a07906c9d9b3dbc7626e4e660caf';
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      // A v0 and a stale v1 next to it, as during a secret roll.
      stripe.verifySignature(
        body,
        't=1700000000,v0=abc,v1=0000,v1=$v1',
        now: at,
      );
      expect(
        () => stripe.verifySignature(body, 't=1700000000,v0=$v1', now: at),
        throwsA(isA<InvalidPaymentSignatureException>()),
        reason: 'only v1 counts',
      );
      expect(
        () => stripe.verifySignature('$body ', 't=1700000000,v1=$v1', now: at),
        throwsA(isA<InvalidPaymentSignatureException>()),
        reason: 'the body is signed byte for byte',
      );
      expect(
        () => stripe.verifySignature(
          body,
          't=1700000000,v1=$v1',
          now: at.add(const Duration(minutes: 6)),
        ),
        throwsA(isA<InvalidPaymentSignatureException>()),
        reason: 'a replay after the tolerance',
      );
    });

    test('status mapping follows the gateways\' documentation', () {
      expect(MidtransGateway.mapStatus('settlement', null), PaymentStatus.paid);
      expect(
        MidtransGateway.mapStatus('capture', 'accept'),
        PaymentStatus.paid,
      );
      expect(
        MidtransGateway.mapStatus('capture', 'challenge'),
        PaymentStatus.pending,
      );
      expect(
        MidtransGateway.mapStatus('capture', 'deny'),
        PaymentStatus.failed,
      );
      expect(MidtransGateway.mapStatus('expire', null), PaymentStatus.expired);
      expect(MidtransGateway.mapStatus('cancel', null), PaymentStatus.failed);
      expect(MidtransGateway.mapStatus('refund', null), PaymentStatus.refunded);
      expect(MidtransGateway.mapStatus('partial_refund', null), isNull);
      expect(XenditGateway.mapStatus('SETTLED'), PaymentStatus.paid);
      expect(XenditGateway.mapStatus('EXPIRED'), PaymentStatus.expired);
      expect(PaymentStatus.paid.canMoveTo(PaymentStatus.pending), isFalse);
      expect(PaymentStatus.expired.canMoveTo(PaymentStatus.paid), isTrue);
      expect(PaymentStatus.refunded.canMoveTo(PaymentStatus.paid), isFalse);
      expect(toMinorUnits(19.99, 'USD'), 1999);
      expect(toMinorUnits(150000, 'IDR'), 15000000);
      expect(toMinorUnits(1500, 'JPY'), 1500);
    });
  });

  group('requests to the gateways', () {
    late Application app;
    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path).withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'LOG_LEVEL': 'error',
      }).create();
      await app.boot();
    });
    tearDown(() async {
      await app.shutdown();
      Container.setRoot(null);
    });

    test(
      'Midtrans Snap: basic auth with the server key, whole rupiah',
      () async {
        await app.run(() async {
          final http = Http.fake({
            'app.sandbox.midtrans.com/snap/v1/transactions': Http.response({
              'token': 'snap-token',
              'redirect_url':
                  'https://app.sandbox.midtrans.com/snap/v4/redirection/x',
            }, 201),
          });
          final checkout = await MidtransGateway(serverKey: serverKey).create(
            const PaymentRequest(
              orderId: 'ORDER-42',
              amount: 150000,
              items: [PaymentItem(name: 'Assessment', price: 150000)],
              customer: PaymentCustomer(name: 'Ayu', email: 'ayu@example.test'),
              methods: ['qris', 'gopay'],
            ),
          );
          expect(checkout.token, 'snap-token');
          final sent = http.recorded.single;
          expect(
            sent.headers.first('authorization'),
            'Basic ${base64.encode(utf8.encode('$serverKey:'))}',
          );
          final body = jsonDecode(sent.body) as Map<String, Object?>;
          expect(body['transaction_details'], {
            'order_id': 'ORDER-42',
            'gross_amount': 150000,
          });
          expect(body['enabled_payments'], ['qris', 'gopay']);
          expect(
            () =>
                MidtransGateway(serverKey: serverKey)
                    .create(const PaymentRequest(orderId: 'X', amount: 10.5)),
            throwsArgumentError,
          );
        });
      },
    );

    test('Stripe Checkout: form fields, amounts in minor units', () async {
      await app.run(() async {
        final http = Http.fake({
          'api.stripe.com/v1/checkout/sessions': Http.response({
            'id': 'cs_test_1',
            'url': 'https://checkout.stripe.com/c/pay/cs_test_1',
          }),
        });
        await StripeGateway(secretKey: 'sk_test_1', webhookSecret: 'w').create(
          const PaymentRequest(
            orderId: 'ORDER-7',
            amount: 19.99,
            currency: 'USD',
            successUrl: 'https://shop.test/ok',
            cancelUrl: 'https://shop.test/cancel',
          ),
        );
        final sent = http.recorded.single;
        expect(sent.headers.first('authorization'), 'Bearer sk_test_1');
        final form = Uri.splitQueryString(sent.body);
        expect(form['line_items[0][price_data][unit_amount]'], '1999');
        expect(form['line_items[0][price_data][currency]'], 'usd');
        expect(form['client_reference_id'], 'ORDER-7');
        expect(form['mode'], 'payment');
      });
    });

    test('Xendit invoice: external_id, and the callback token', () async {
      await app.run(() async {
        final http = Http.fake({
          'api.xendit.co/v2/invoices': Http.response({
            'id': 'inv-1',
            'invoice_url': 'https://checkout-staging.xendit.co/web/inv-1',
            'status': 'PENDING',
          }),
        });
        final xendit = XenditGateway(
          secretKey: 'xnd_dev',
          callbackToken: 'tok',
        );
        final checkout = await xendit.create(
          const PaymentRequest(orderId: 'ORDER-9', amount: 50000),
        );
        expect(checkout.reference, 'inv-1');
        final body =
            jsonDecode(http.recorded.single.body) as Map<String, Object?>;
        expect(body['external_id'], 'ORDER-9');
        expect(body['amount'], 50000);

        final callback = jsonEncode({
          'id': 'inv-1',
          'external_id': 'ORDER-9',
          'status': 'PAID',
          'amount': 50000,
          'paid_amount': 50000,
          'payment_channel': 'QRIS',
          'paid_at': '2026-10-29T08:00:00.000Z',
        });
        final event = await xendit.parseWebhook(
          Request.fake(
            method: 'POST',
            path: '/payments/webhook/xendit',
            headers: {'x-callback-token': 'tok'},
            body: callback,
          ),
        );
        expect(event.status, PaymentStatus.paid);
        expect(event.amount, 50000);
        await expectLater(
          xendit.parseWebhook(
            Request.fake(
              method: 'POST',
              path: '/x',
              headers: {'x-callback-token': 'nope'},
              body: callback,
            ),
          ),
          throwsA(isA<InvalidPaymentSignatureException>()),
        );
      });
    });
  });

  group('webhooks, exactly once', () {
    late Directory dir;
    late Application app;
    late List<Object> events;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('daravel_payments_');
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
              ..listen<PaymentAmountMismatch>(events.add)
              ..listen<PaymentExpired>(events.add);
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
        await Payment.checkout(
          const PaymentRequest(orderId: 'ORDER-42', amount: 150000),
        );
      });
    });
    tearDown(() async {
      await app.shutdown();
      Container.setRoot(null);
      dir.deleteSync(recursive: true);
    });

    Future<(int, String)> notify(Map<String, Object?> body) async {
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/payments/webhook/midtrans',
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        ),
      );
      final text = await response.bodyText();
      return (response.status, text);
    }

    Future<PaymentRecord> record() async =>
        (await app.run<PaymentRecord?>(() => Payment.find('ORDER-42')))!;

    test('paid once, events after commit; the retry is a duplicate', () async {
      expect((await record()).status, PaymentStatus.pending);
      final paid = midtransNotification();
      expect(await notify(paid), (200, '{"status":"applied"}'));
      final payment = await record();
      expect(payment.status, PaymentStatus.paid);
      expect(payment.paymentType, 'qris');
      expect(payment.paidAt, DateTime.utc(2026, 10, 29, 8, 1));
      expect(events.single, isA<PaymentPaid>());

      expect(await notify(paid), (200, '{"status":"duplicate"}'));
      expect(events, hasLength(1), reason: 'not dispatched twice');
    });

    test('a forged notification is refused and changes nothing', () async {
      final forged = midtransNotification()..['gross_amount'] = '1.00';
      final (status, _) = await notify(forged);
      expect(status, 401);
      expect((await record()).status, PaymentStatus.pending);
    });

    test('a signed amount that is not the order\'s changes nothing', () async {
      final short = midtransNotification(grossAmount: '1500.00');
      expect(await notify(short), (200, '{"status":"amountMismatch"}'));
      expect((await record()).status, PaymentStatus.pending);
      expect(events.single, isA<PaymentAmountMismatch>());
    });

    test('a late pending never takes a paid order back', () async {
      await notify(midtransNotification());
      final late = midtransNotification(
        status: 'pending',
        statusCode: '201',
        transactionId: 'tx-1',
      );
      expect(await notify(late), (200, '{"status":"ignored"}'));
      expect((await record()).status, PaymentStatus.paid);
    });

    test('expired, then paid after all; unknown orders are reported', () async {
      expect(
        await notify(midtransNotification(status: 'expire', statusCode: '407')),
        (200, '{"status":"applied"}'),
      );
      expect((await record()).status, PaymentStatus.expired);
      expect(await notify(midtransNotification(orderId: 'ORDER-404')), (
        200,
        '{"status":"unknownOrder"}',
      ));
    });

    test('Payment.fake() records what the application starts', () async {
      await app.run(() async {
        final fake = Payment.fake();
        final checkout = await Payment.checkout(
          const PaymentRequest(orderId: 'ORDER-43', amount: 99000),
          gateway: 'midtrans',
        );
        expect(checkout.redirectUrl, startsWith('https://payments.fake.test/'));
        fake.assertCreated((r) => r.amount == 99000);
        expect(
          () => fake.assertCreated((r) => r.amount == 1),
          throwsStateError,
        );
        final outcome = await Payment.manager.apply(
          fake.named('midtrans').event('ORDER-43', PaymentStatus.paid),
        );
        expect(outcome, PaymentOutcome.applied);
      });
      expect(events.whereType<PaymentPaid>(), hasLength(1));
    });
  });

  test(
    'Midtrans sandbox: Snap creates a transaction, status reads it',
    () async {
      final key = Platform.environment['MIDTRANS_SERVER_KEY']!;
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .create();
      await app.boot();
      addTearDown(() async {
        await app.shutdown();
        Container.setRoot(null);
      });
      await app.run(() async {
        final midtrans = MidtransGateway(serverKey: key);
        final order = 'daravel-test-${DateTime.now().millisecondsSinceEpoch}';
        final checkout = await midtrans.create(
          PaymentRequest(orderId: order, amount: 15000),
        );
        expect(
          checkout.redirectUrl,
          startsWith('https://app.sandbox.midtrans.com/'),
        );
        // Nothing chosen on the Snap page yet: pending.
        final status = await midtrans.status(order);
        expect(status.status, PaymentStatus.pending);
      });
    },
    tags: ['integration'],
    skip: Platform.environment['MIDTRANS_SERVER_KEY'] == null
        ? 'MIDTRANS_SERVER_KEY (a sandbox key) not set'
        : false,
  );
}
