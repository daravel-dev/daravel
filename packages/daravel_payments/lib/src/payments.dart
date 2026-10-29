import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'fake.dart';
import 'midtrans.dart';
import 'stripe.dart';
import 'types.dart';
import 'xendit.dart';

/// The `PAYMENT_*`, `MIDTRANS_*`, `XENDIT_*` and `STRIPE_*` settings (the
/// names of the gateways' Laravel packages: midtrans-php's
/// `MIDTRANS_IS_PRODUCTION`, Cashier's `STRIPE_SECRET`).
final class PaymentsConfig implements ConfigSection {
  const PaymentsConfig({
    this.defaultGateway = 'midtrans',
    this.midtransServerKey,
    this.midtransProduction = false,
    this.xenditSecretKey,
    this.xenditWebhookToken,
    this.stripeSecret,
    this.stripeWebhookSecret,
  });

  factory PaymentsConfig.fromEnv(Env env) {
    String? read(String key) {
      final value = env.maybeString(key);
      return value == null || value.isEmpty ? null : value;
    }

    return PaymentsConfig(
      defaultGateway: env.string('PAYMENT_GATEWAY', 'midtrans'),
      midtransServerKey: read('MIDTRANS_SERVER_KEY'),
      midtransProduction: env.boolean('MIDTRANS_IS_PRODUCTION', false),
      xenditSecretKey: read('XENDIT_SECRET_KEY'),
      xenditWebhookToken: read('XENDIT_WEBHOOK_TOKEN'),
      stripeSecret: read('STRIPE_SECRET'),
      stripeWebhookSecret: read('STRIPE_WEBHOOK_SECRET'),
    );
  }

  final String defaultGateway;
  final String? midtransServerKey;
  final bool midtransProduction;
  final String? xenditSecretKey;
  final String? xenditWebhookToken;
  final String? stripeSecret;
  final String? stripeWebhookSecret;

  @override
  String get key => 'payments';

  /// Never the keys themselves.
  @override
  Map<String, Object?> toMap() => {
    'default': defaultGateway,
    'midtrans': midtransServerKey != null,
    'midtrans_production': midtransProduction,
    'xendit': xenditSecretKey != null && xenditWebhookToken != null,
    'stripe': stripeSecret != null && stripeWebhookSecret != null,
  };
}

/// A row of `payment_transactions`.
final class PaymentRecord {
  const PaymentRecord({
    required this.id,
    required this.orderId,
    required this.gateway,
    required this.amount,
    required this.currency,
    required this.status,
    this.reference,
    this.paymentType,
    this.paidAt,
    this.metadata = const {},
  });

  factory PaymentRecord.fromRow(Map<String, Object?> row) {
    final metadata = row['metadata'];
    final paidAt = row['paid_at'];
    return PaymentRecord(
      id: row['id']!,
      orderId: row['order_id']! as String,
      gateway: row['gateway']! as String,
      reference: row['gateway_reference'] as String?,
      amount: num.parse('${row['amount']}'),
      currency: row['currency']! as String,
      status: PaymentStatus.parse(row['status']! as String),
      paymentType: row['payment_type'] as String?,
      paidAt: paidAt == null ? null : DateTime.parse('$paidAt'),
      metadata: metadata is String && metadata.isNotEmpty
          ? (jsonDecode(metadata) as Map<String, Object?>)
          : const {},
    );
  }

  final Object id;
  final String orderId;
  final String gateway;
  final String? reference;
  final num amount;
  final String currency;
  final PaymentStatus status;
  final String? paymentType;
  final DateTime? paidAt;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
    'order_id': orderId,
    'gateway': gateway,
    'reference': reference,
    'amount': amount,
    'currency': currency,
    'status': status.name,
    'payment_type': paymentType,
    'paid_at': paidAt?.toUtc().toIso8601String(),
  };
}

/// Dispatched after the commit that marked a payment paid.
final class PaymentPaid {
  const PaymentPaid(this.payment, this.event);
  final PaymentRecord payment;
  final PaymentEvent event;
}

/// Dispatched after the commit that marked a payment failed.
final class PaymentFailed {
  const PaymentFailed(this.payment, this.event);
  final PaymentRecord payment;
  final PaymentEvent event;
}

/// Dispatched after the commit that marked a payment expired.
final class PaymentExpired {
  const PaymentExpired(this.payment, this.event);
  final PaymentRecord payment;
  final PaymentEvent event;
}

/// Dispatched after the commit that marked a payment refunded.
final class PaymentRefunded {
  const PaymentRefunded(this.payment, this.event);
  final PaymentRecord payment;
  final PaymentEvent event;
}

/// A verified notification whose amount is not the order's: nothing was
/// changed. Worth an alert.
final class PaymentAmountMismatch {
  const PaymentAmountMismatch(this.payment, this.event);
  final PaymentRecord payment;
  final PaymentEvent event;
}

/// What [PaymentManager.apply] did with an event.
enum PaymentOutcome {
  /// The payment moved to the event's status.
  applied,

  /// This event was handled before (the idempotency log has it).
  duplicate,

  /// The payment is in that status already.
  unchanged,

  /// A move that cannot happen (a late `pending` after `paid`), or an
  /// event that says nothing about the status.
  ignored,

  /// No payment with that order id and gateway.
  unknownOrder,

  /// The amount is not the order's; nothing changed.
  amountMismatch,
}

/// Gateways, the transactions table and the webhook logic.
final class PaymentManager {
  PaymentManager(this.config, {Map<String, PaymentGateway>? gateways})
    : _gateways = {...?gateways};

  static const String transactionsTable = 'payment_transactions';
  static const String webhookLogTable = 'payment_webhook_logs';

  final PaymentsConfig config;
  final Map<String, PaymentGateway> _gateways;
  FakePaymentGateway? _fake;

  /// The fake installed by `Payment.fake()`, if any.
  FakePaymentGateway? get fake => _fake;

  /// Adds (or replaces) a gateway, e.g. a second Midtrans account.
  void register(PaymentGateway gateway) => _gateways[gateway.name] = gateway;

  /// The gateway [name] (the default one when null), built from the
  /// settings the first time.
  PaymentGateway gateway([String? name]) {
    final key = name ?? config.defaultGateway;
    final fake = _fake;
    if (fake != null) {
      return fake.named(key);
    }
    return _gateways[key] ??= _build(key);
  }

  PaymentGateway _build(String name) {
    final c = config;
    switch (name) {
      case 'midtrans' when c.midtransServerKey != null:
        return MidtransGateway(
          serverKey: c.midtransServerKey!,
          production: c.midtransProduction,
        );
      case 'xendit'
          when c.xenditSecretKey != null && c.xenditWebhookToken != null:
        return XenditGateway(
          secretKey: c.xenditSecretKey!,
          callbackToken: c.xenditWebhookToken!,
        );
      case 'stripe'
          when c.stripeSecret != null && c.stripeWebhookSecret != null:
        return StripeGateway(
          secretKey: c.stripeSecret!,
          webhookSecret: c.stripeWebhookSecret!,
        );
      case 'midtrans' || 'xendit' || 'stripe':
        throw ConfigException('The $name gateway has no keys in .env.');
      default:
        throw NotFoundHttpException('No payment gateway [$name].');
    }
  }

  /// Replaces every gateway with a [FakePaymentGateway].
  FakePaymentGateway installFake() => _fake = FakePaymentGateway();

  void removeFake() => _fake = null;

  /// Starts a payment at [gateway] and records it as `pending`.
  Future<PaymentCheckout> checkout(
    PaymentRequest request, {
    String? gateway,
  }) async {
    final target = this.gateway(gateway);
    final checkout = await target.create(request);
    final now = Clock.now().toUtc();
    await DB.table(transactionsTable).insert({
      'order_id': request.orderId,
      'gateway': target.name,
      'gateway_reference': checkout.reference,
      'amount': request.amount,
      'currency': request.currency.toUpperCase(),
      'status': PaymentStatus.pending.name,
      'payer_email': request.customer?.email,
      'payer_name': request.customer?.name,
      'metadata': request.metadata.isEmpty
          ? null
          : jsonEncode(request.metadata),
      'created_at': now,
      'updated_at': now,
    });
    return checkout;
  }

  /// The payment of [orderId], if recorded.
  Future<PaymentRecord?> find(String orderId, {String? gateway}) async {
    var query = DB.table(transactionsTable).where('order_id', orderId);
    if (gateway != null) {
      query = query.where('gateway', gateway);
    }
    final row = await query.first();
    return row == null ? null : PaymentRecord.fromRow(row);
  }

  /// Verifies a webhook for [gateway] and applies it.
  Future<PaymentOutcome> handleWebhook(String gateway, Request request) async =>
      apply(await this.gateway(gateway).parseWebhook(request));

  /// Asks the gateway about [orderId] and applies the answer (for
  /// missed webhooks: `dartisan payment:check`).
  Future<PaymentOutcome> reconcile(String orderId) async {
    final record = await find(orderId);
    if (record == null) {
      return PaymentOutcome.unknownOrder;
    }
    final event = await gateway(record.gateway)
        .status(orderId, reference: record.reference);
    return apply(event);
  }

  /// Applies a verified event, exactly once: in one transaction, the event
  /// id goes into the idempotency log (a second delivery stops there),
  /// the payment row is locked, its amount compared with the event's, and
  /// its status moved when the move is possible. Events are dispatched
  /// after the commit.
  Future<PaymentOutcome> apply(PaymentEvent event) => DB.transaction(() async {
    final now = Clock.now().toUtc();
    try {
      // A savepoint: a duplicate fails only this insert.
      await DB.transaction(
        () => DB.table(webhookLogTable).insert({
          'gateway': event.gateway,
          'event_id': event.eventId,
          'order_id': event.orderId,
          'payload': jsonEncode(event.raw),
          'processed': true,
          'created_at': now,
          'updated_at': now,
        }),
      );
    } on UniqueConstraintViolationException {
      return PaymentOutcome.duplicate;
    }
    Future<void> unprocessed() => DB
        .table(webhookLogTable)
        .where('gateway', event.gateway)
        .where('event_id', event.eventId)
        .update({'processed': false});

    final row = await DB
        .table(transactionsTable)
        .where('gateway', event.gateway)
        .where('order_id', event.orderId)
        .lockForUpdate()
        .first();
    if (row == null) {
      await unprocessed();
      return PaymentOutcome.unknownOrder;
    }
    final payment = PaymentRecord.fromRow(row);
    final next = event.status;
    if (next == null) {
      return PaymentOutcome.ignored;
    }
    final amount = event.amount;
    if (amount != null &&
        toMinorUnits(amount, payment.currency) !=
            toMinorUnits(payment.amount, payment.currency)) {
      await unprocessed();
      await Event.dispatchAfterCommit(PaymentAmountMismatch(payment, event));
      return PaymentOutcome.amountMismatch;
    }
    if (payment.status == next) {
      return PaymentOutcome.unchanged;
    }
    if (!payment.status.canMoveTo(next)) {
      return PaymentOutcome.ignored;
    }
    final paidAt = next == PaymentStatus.paid
        ? (event.occurredAt ?? now).toUtc()
        : payment.paidAt;
    await DB.table(transactionsTable).where('id', payment.id).update({
      'status': next.name,
      'payment_type': event.paymentType ?? payment.paymentType,
      'paid_at': paidAt,
      'updated_at': now,
    });
    final updated = PaymentRecord(
      id: payment.id,
      orderId: payment.orderId,
      gateway: payment.gateway,
      reference: payment.reference,
      amount: payment.amount,
      currency: payment.currency,
      status: next,
      paymentType: event.paymentType ?? payment.paymentType,
      paidAt: paidAt,
      metadata: payment.metadata,
    );
    await switch (next) {
      PaymentStatus.paid => Event.dispatchAfterCommit(
        PaymentPaid(updated, event),
      ),
      PaymentStatus.failed => Event.dispatchAfterCommit(
        PaymentFailed(updated, event),
      ),
      PaymentStatus.expired => Event.dispatchAfterCommit(
        PaymentExpired(updated, event),
      ),
      PaymentStatus.refunded => Event.dispatchAfterCommit(
        PaymentRefunded(updated, event),
      ),
      PaymentStatus.pending => Future<void>.value(),
    };
    return PaymentOutcome.applied;
  });
}

/// The payments facade.
abstract final class Payment {
  static PaymentManager get manager => App.make<PaymentManager>();

  /// The gateway [name] (`PAYMENT_GATEWAY` when null).
  static PaymentGateway gateway([String? name]) => manager.gateway(name);

  /// Starts a payment and records it as pending.
  static Future<PaymentCheckout> checkout(
    PaymentRequest request, {
    String? gateway,
  }) => manager.checkout(request, gateway: gateway);

  static Future<PaymentRecord?> find(String orderId) => manager.find(orderId);

  /// Records gateway calls instead of making them (Laravel's fakes).
  static FakePaymentGateway fake() => manager.installFake();

  /// `POST <path>/{gateway}`: verifies and applies the gateway's
  /// notifications, answering 200 (the gateway stops retrying) with what
  /// happened, 401 for a bad signature, 404 for an unknown gateway.
  static void webhookRoutes(
    Router router, {
    String path = '/payments/webhook',
    List<Object> middleware = const [],
  }) {
    router.group((r) {
      r
          .post('$path/{gateway}', (Request request) async {
            final outcome = await manager.handleWebhook(
              request.param<String>('gateway'),
              request,
            );
            return Response.json({'status': outcome.name});
          })
          .name('payments.webhook');
    }, middleware: middleware);
  }
}
