import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'types.dart';

/// Stripe Checkout (hosted payment page) and its signed webhooks
/// (https://docs.stripe.com/webhooks#verify-manually): `Stripe-Signature`
/// carries `t=<timestamp>` and `v1=<HMAC-SHA256 of "t.body">` signatures.
final class StripeGateway implements PaymentGateway {
  StripeGateway({
    required this.secretKey,
    required this.webhookSecret,
    this.name = 'stripe',
    this.tolerance = const Duration(minutes: 5),
    this.baseUrl = 'https://api.stripe.com',
  });

  @override
  final String name;

  /// `sk_test_...` / `sk_live_...`.
  final String secretKey;

  /// The endpoint's signing secret (`whsec_...`).
  final String webhookSecret;

  /// How old a signed timestamp may be (replay protection; Stripe's
  /// libraries use five minutes).
  final Duration tolerance;
  final String baseUrl;

  PendingRequest get _http => Http.withToken(secretKey).acceptJson().asForm();

  @override
  Future<PaymentCheckout> create(PaymentRequest request) async {
    final currency = request.currency.toLowerCase();
    final items = request.items.isNotEmpty
        ? request.items
        : [
            PaymentItem(
              name: request.description ?? request.orderId,
              price: request.amount,
            ),
          ];
    final form = <String, String>{
      'mode': 'payment',
      'client_reference_id': request.orderId,
      'metadata[order_id]': request.orderId,
      'payment_intent_data[metadata][order_id]': request.orderId,
      'success_url': ?request.successUrl,
      'cancel_url': ?request.cancelUrl,
      'customer_email': ?request.customer?.email,
      for (final (i, item) in items.indexed) ...{
        'line_items[$i][quantity]': '${item.quantity}',
        'line_items[$i][price_data][currency]': currency,
        'line_items[$i][price_data][unit_amount]':
            '${toMinorUnits(item.price, currency)}',
        'line_items[$i][price_data][product_data][name]': item.name,
      },
      for (final (i, method) in request.methods.indexed)
        'payment_method_types[$i]': method,
      for (final MapEntry(:key, :value) in request.metadata.entries)
        'metadata[$key]': '$value',
    };
    final response = await _http.post(
      '$baseUrl/v1/checkout/sessions',
      form: form,
    );
    if (!response.successful) {
      throw PaymentGatewayException(
        'Stripe refused the Checkout Session (${response.status}).',
        status: response.status,
        body: response.body,
      );
    }
    final body = jsonDecode(response.body) as Map<String, Object?>;
    return PaymentCheckout(
      gateway: name,
      orderId: request.orderId,
      reference: body['id']! as String,
      redirectUrl: body['url']! as String,
      raw: body,
    );
  }

  @override
  Future<PaymentEvent> status(String orderId, {String? reference}) async {
    if (reference == null) {
      throw ArgumentError.notNull('reference (the Checkout Session id)');
    }
    final response = await _http.get(
      '$baseUrl/v1/checkout/sessions/${Uri.encodeComponent(reference)}',
    );
    if (!response.successful) {
      throw PaymentGatewayException(
        'Stripe status failed (${response.status}).',
        status: response.status,
        body: response.body,
      );
    }
    final session = jsonDecode(response.body) as Map<String, Object?>;
    final status = switch ((session['status'], session['payment_status'])) {
      (_, 'paid' || 'no_payment_required') => PaymentStatus.paid,
      ('expired', _) => PaymentStatus.expired,
      _ => PaymentStatus.pending,
    };
    return _session(session, status, 'status:${session['id']}:${status.name}');
  }

  @override
  Future<PaymentEvent> parseWebhook(Request request) async {
    final payload = utf8.decode(await request.bytes());
    verifySignature(
      payload,
      request.headers.first('stripe-signature') ?? '',
      now: Clock.now(),
    );
    final event = jsonDecode(payload) as Map<String, Object?>;
    final data = event['data'] as Map<String, Object?>?;
    final object =
        (data?['object'] ?? const <String, Object?>{}) as Map<String, Object?>;
    final status = switch (event['type']) {
      'checkout.session.completed' =>
        object['payment_status'] == 'paid'
            ? PaymentStatus.paid
            : PaymentStatus.pending,
      'checkout.session.async_payment_succeeded' => PaymentStatus.paid,
      'checkout.session.async_payment_failed' => PaymentStatus.failed,
      'checkout.session.expired' => PaymentStatus.expired,
      _ => null,
    };
    return _session(object, status, '${event['id']}');
  }

  /// Throws [InvalidPaymentSignatureException] unless [header] holds a
  /// `v1` signature of `"<t>.<payload>"` by [webhookSecret] with a `t`
  /// within [tolerance] of [now]. Other schemes (`v0`) are ignored, as
  /// Stripe asks, against downgrades.
  void verifySignature(String payload, String header, {required DateTime now}) {
    int? timestamp;
    final signatures = <String>[];
    for (final part in header.split(',')) {
      final at = part.indexOf('=');
      if (at < 0) {
        continue;
      }
      final key = part.substring(0, at).trim();
      final value = part.substring(at + 1).trim();
      if (key == 't') {
        timestamp = int.tryParse(value);
      } else if (key == 'v1') {
        signatures.add(value);
      }
    }
    if (timestamp == null || signatures.isEmpty) {
      throw const InvalidPaymentSignatureException();
    }
    final expected = hmacSha256Hex(webhookSecret, '$timestamp.$payload');
    if (!signatures.any((s) => constantTimeEquals(s, expected))) {
      throw const InvalidPaymentSignatureException();
    }
    final age = now.millisecondsSinceEpoch ~/ 1000 - timestamp;
    if (age.abs() > tolerance.inSeconds) {
      throw const InvalidPaymentSignatureException(
        'Stripe signature timestamp outside the tolerance.',
      );
    }
  }

  PaymentEvent _session(
    Map<String, Object?> session,
    PaymentStatus? status,
    String eventId,
  ) {
    final currency = (session['currency'] as String?)?.toUpperCase();
    final total = session['amount_total'] as int?;
    final metadata = session['metadata'] as Map<String, Object?>?;
    return PaymentEvent(
      gateway: name,
      eventId: eventId,
      orderId:
          (session['client_reference_id'] ?? metadata?['order_id'] ?? '')
              as String,
      status: status,
      amount: total == null || currency == null
          ? null
          : fromMinorUnits(total, currency),
      currency: currency,
      paymentType:
          (session['payment_method_types'] as List<Object?>?)?.firstOrNull
              as String?,
      reference: session['id'] as String?,
      raw: session,
    );
  }
}
