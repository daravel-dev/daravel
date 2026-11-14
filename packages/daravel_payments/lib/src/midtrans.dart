import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'secrets.dart';
import 'types.dart';
import 'webhook_checks.dart';

/// Midtrans: Snap for paying (QRIS, virtual accounts, e-wallets, cards)
/// and HTTP notifications for the result
/// (https://docs.midtrans.com/docs/https-notification-webhooks).
final class MidtransGateway implements PaymentGateway {
  /// Midtrans Snap, with the server key from `MIDTRANS_SERVER_KEY`; an
  /// empty or blank key is an [ArgumentError].
  MidtransGateway({
    required String serverKey,
    this.production = false,
    this.name = 'midtrans',
  }) : serverKey = requireSecret(serverKey, 'serverKey');

  @override
  final String name;

  /// The Server Key (`SB-Mid-server-...` in the sandbox). It signs the
  /// requests and the notifications; never send it to a client.
  final String serverKey;

  /// `api.midtrans.com` rather than the sandbox.
  final bool production;

  String get _snap => production
      ? 'https://app.midtrans.com/snap/v1/transactions'
      : 'https://app.sandbox.midtrans.com/snap/v1/transactions';

  String get _api => production
      ? 'https://api.midtrans.com'
      : 'https://api.sandbox.midtrans.com';

  PendingRequest get _http =>
      Http.withBasicAuth(serverKey, '').acceptJson().asJson();

  static int _rupiah(num amount) {
    if (amount != amount.roundToDouble()) {
      throw ArgumentError.value(
        amount,
        'amount',
        'Midtrans takes whole rupiah',
      );
    }
    return amount.round();
  }

  @override
  Future<PaymentCheckout> create(PaymentRequest request) async {
    if (request.currency.toUpperCase() != 'IDR') {
      throw ArgumentError.value(
        request.currency,
        'currency',
        'Midtrans charges IDR',
      );
    }
    final customer = request.customer;
    final response = await _http.post(
      _snap,
      json: {
        'transaction_details': {
          'order_id': request.orderId,
          'gross_amount': _rupiah(request.amount),
        },
        if (request.items.isNotEmpty)
          'item_details': [
            for (final (i, item) in request.items.indexed)
              {
                'id': item.id ?? '${i + 1}',
                'name': item.name.length > 50
                    ? item.name.substring(0, 50)
                    : item.name,
                'price': _rupiah(item.price),
                'quantity': item.quantity,
              },
          ],
        if (customer != null)
          'customer_details': {
            'first_name': ?customer.name,
            'email': ?customer.email,
            'phone': ?customer.phone,
          },
        if (request.methods.isNotEmpty) 'enabled_payments': request.methods,
        if (request.successUrl != null)
          'callbacks': {'finish': request.successUrl},
        if (request.metadata.isNotEmpty)
          'custom_field1': jsonEncode(request.metadata),
      },
    );
    if (response.status != 201 && response.status != 200) {
      throw PaymentGatewayException(
        'Midtrans refused the transaction (${response.status}).',
        status: response.status,
        body: response.body,
      );
    }
    final body = jsonDecode(response.body) as Map<String, Object?>;
    final token = body['token']! as String;
    return PaymentCheckout(
      gateway: name,
      orderId: request.orderId,
      reference: token,
      token: token,
      redirectUrl: body['redirect_url']! as String,
      raw: body,
    );
  }

  @override
  Future<PaymentEvent> status(String orderId, {String? reference}) async {
    final response = await _http.get(
      '$_api/v2/${Uri.encodeComponent(orderId)}/status',
    );
    final body = jsonDecode(response.body) as Map<String, Object?>;
    // Midtrans answers 200 with status_code "404" until the customer has
    // chosen a payment method on the Snap page.
    if ('${body['status_code']}' == '404') {
      return PaymentEvent(
        gateway: name,
        eventId: 'status:$orderId:pending',
        orderId: orderId,
        status: PaymentStatus.pending,
        amount: null,
        raw: body,
      );
    }
    if (!response.successful) {
      throw PaymentGatewayException(
        'Midtrans status failed (${response.status}).',
        status: response.status,
        body: response.body,
      );
    }
    return _event(body, prefix: 'status:');
  }

  @override
  Future<PaymentEvent> parseWebhook(Request request) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(await request.bytes()));
    } on FormatException {
      throw const InvalidPaymentSignatureException(
        'Not a Midtrans notification.',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const InvalidPaymentSignatureException(
        'Not a Midtrans notification.',
      );
    }
    final body = decoded;
    final signature = body['signature_key'];
    if (signature is! String ||
        !constantTimeEquals(signature.toLowerCase(), signatureFor(body))) {
      throw const InvalidPaymentSignatureException();
    }
    final transactionStatus = '${body['transaction_status']}';
    // The signature covers status_code, not transaction_status: a status
    // must agree with the code signed for it.
    final expected = signedStatusCodes[transactionStatus];
    if (expected != null && _code(body['status_code']) != expected) {
      throw const InvalidPaymentSignatureException(
        'The Midtrans transaction_status does not match the signed '
        'status_code.',
      );
    }
    final event = _event(body);
    if (expected != null || transactionStatus == 'pending') {
      return requireAmountWhenPaid(event);
    }
    // Any other status (deny, refund, partial_refund, chargeback,
    // authorize, failure, one not known) is taken from Midtrans' status
    // API, not from the notification; the notification's id is kept, so a
    // retry is still a duplicate. An API that fails answers 5xx, and
    // nothing is applied.
    final confirmed = await status(event.orderId, reference: event.reference);
    return requireAmountWhenPaid(
      PaymentEvent(
        gateway: confirmed.gateway,
        eventId: event.eventId,
        orderId: event.orderId,
        status: confirmed.status,
        amount: confirmed.amount,
        currency: confirmed.currency,
        paymentType: confirmed.paymentType,
        reference: confirmed.reference,
        occurredAt: confirmed.occurredAt,
        raw: confirmed.raw,
      ),
    );
  }

  /// The `status_code` a `transaction_status` comes with in Midtrans'
  /// sample notifications: 200 for `capture` and `settlement`
  /// (docs.midtrans.com/docs/https-notification-webhooks), 202 for
  /// `expire` (docs.midtrans.com/reference/expire-transaction, "Expired
  /// Notification") and for `cancel`
  /// (docs.midtrans.com/reference/cancel-transaction, "Success
  /// Notification"). A notification whose status disagrees with its signed
  /// code is refused. `pending` is not checked: it moves no payment. Every
  /// other status, which no sample pairs with a code (`deny`, `refund`,
  /// `partial_refund`, `chargeback`, `authorize`, `failure`), is confirmed
  /// with the status API instead.
  static const Map<String, String> signedStatusCodes = {
    'capture': '200',
    'settlement': '200',
    'expire': '202',
    'cancel': '202',
  };

  /// A `status_code` as text: Midtrans sends `"200"`; a whole number
  /// (`200`) reads the same, anything else does not match.
  static String? _code(Object? value) => switch (value) {
    final String text => text,
    final int number => '$number',
    final double number
        when number == number.truncateToDouble() && number.isFinite =>
      '${number.toInt()}',
    _ => null,
  };

  /// `SHA512(order_id + status_code + gross_amount + ServerKey)`, as
  /// Midtrans signs its notifications.
  String signatureFor(Map<String, Object?> body) => sha512Hex(
    '${body['order_id']}${body['status_code']}${body['gross_amount']}$serverKey',
  );

  PaymentEvent _event(Map<String, Object?> body, {String prefix = ''}) {
    final status = '${body['transaction_status']}';
    final fraud = body['fraud_status'] as String?;
    final orderId = '${body['order_id']}';
    final transaction = body['transaction_id'] as String? ?? orderId;
    final time =
        (body['settlement_time'] ?? body['transaction_time']) as String?;
    return PaymentEvent(
      gateway: name,
      // The fraud status is part of the key: a `capture` held for review
      // (`challenge`) is followed by the same `capture` once accepted.
      eventId: '$prefix$transaction:$status${fraud == null ? '' : ':$fraud'}',
      orderId: orderId,
      status: mapStatus(status, fraud),
      amount: num.tryParse('${body['gross_amount']}'),
      currency: body['currency'] as String? ?? 'IDR',
      paymentType: body['payment_type'] as String?,
      reference: body['transaction_id'] as String?,
      // Midtrans times are Jakarta time (UTC+7) without an offset.
      occurredAt: time == null
          ? null
          : DateTime.tryParse('${time.replaceFirst(' ', 'T')}+07:00'),
      raw: body,
    );
  }

  /// Midtrans' `transaction_status` (and `fraud_status`) as a
  /// [PaymentStatus]: paid on `settlement` or `capture` unless a fraud
  /// status is there and is not `accept` (`deny` fails, `challenge`
  /// waits; Midtrans' notification guide). A partial refund is not a status
  /// change (`null`).
  static PaymentStatus? mapStatus(String status, String? fraud) =>
      switch (status) {
        'settlement' || 'capture' =>
          fraud == null || fraud == 'accept'
              ? PaymentStatus.paid
              : (fraud == 'deny'
                    ? PaymentStatus.failed
                    : PaymentStatus.pending),
        'pending' || 'authorize' => PaymentStatus.pending,
        'deny' || 'cancel' || 'failure' => PaymentStatus.failed,
        'expire' => PaymentStatus.expired,
        'refund' => PaymentStatus.refunded,
        _ => null,
      };
}
