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
    final body = apiObject(response, 'Midtrans status');
    // Midtrans answers 200 with status_code "404" until the customer has
    // chosen a payment method on the Snap page.
    if (_code(body['status_code']) == '404') {
      return PaymentEvent(
        gateway: name,
        eventId: 'status:$orderId:-:pending',
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
    // The answer must be about the order asked for: anything else is not
    // applied to it.
    if ('${body['order_id']}' != orderId) {
      throw PaymentGatewayException(
        'Midtrans status for $orderId answered for another order.',
        status: response.status,
        body: response.body,
      );
    }
    return _event(body, prefix: 'status:', fromApi: true);
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
    // The signature covers order_id, status_code and gross_amount only.
    // Every other field is read as text or refused (400), whichever path
    // follows, and the transaction id must be there.
    final event = _event(body);
    final transaction = notificationText(body, 'transaction_id');
    if (transaction == null || transaction.trim().isEmpty) {
      throw const BadRequestHttpException(
        'A Midtrans notification without its transaction_id.',
      );
    }
    final transactionStatus = notificationText(body, 'transaction_status');
    final fraud = notificationText(body, 'fraud_status');
    // One thing is taken from the notification itself: a payment, which
    // Midtrans signs with status_code 200 and whose amount is signed.
    // pending moves no payment and is taken as it is too.
    if (((transactionStatus == 'settlement' ||
                transactionStatus == 'capture') &&
            _code(body['status_code']) == '200' &&
            (fraud == null || fraud == 'accept')) ||
        transactionStatus == 'pending') {
      return requireAmountWhenPaid(event);
    }
    // Everything else (expire, cancel, deny, refund, partial_refund,
    // chargeback, authorize, failure, a fraud status other than accept, a
    // status_code other than the one a payment comes with, a status not
    // known) is taken from Midtrans' status API, not from the notification.
    // The event id is the one a genuine notification of the answered
    // status carries (this order, the API's transaction, that status and
    // fraud status), so that notification is a duplicate when it comes and
    // a later status is an event of its own. An API that fails answers
    // 5xx, and nothing is applied.
    final confirmed = await _confirm(
      event.orderId,
      signature.toLowerCase(),
      transactionStatus,
    );
    final answered = switch (confirmed.raw['transaction_status']) {
      final String status => status,
      _ => 'pending',
    };
    final answeredFraud = confirmed.raw['fraud_status'];
    return requireAmountWhenPaid(
      PaymentEvent(
        gateway: confirmed.gateway,
        eventId:
            '${event.orderId}:${confirmed.reference ?? '-'}:$answered'
            '${answeredFraud is String ? ':$answeredFraud' : ''}',
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

  /// How long a status API answer is reused for the same signed
  /// notification: a notification Midtrans signed can be posted again and
  /// again, and each would otherwise call the status API.
  static const Duration confirmationWindow = Duration(seconds: 60);

  /// How many answers are kept for [confirmationWindow], per gateway in
  /// each isolate; the oldest goes first.
  static const int confirmationMemoSize = 1000;

  final Map<String, ({DateTime at, PaymentEvent event})> _confirmations = {};

  /// The status API's answer for [orderId], reused for
  /// [confirmationWindow] when the same signed notification (its
  /// [signature]) of the same kind of status comes again. The kind keeps
  /// two genuine notifications that share a signature apart (`expire` and
  /// `cancel` are both signed 202 for the same amount); a status not known
  /// is one kind, so a notification posted under endless made-up statuses
  /// calls the API once per window. A failed call is not kept. Calls are
  /// not shared while they run: deliveries of one notification at the same
  /// moment each call the API once, before the first answer is kept.
  Future<PaymentEvent> _confirm(
    String orderId,
    String signature,
    String? transactionStatus,
  ) async {
    final kind = switch (transactionStatus) {
      'capture' ||
      'settlement' ||
      'pending' ||
      'deny' ||
      'cancel' => '$transactionStatus',
      'expire' ||
      'refund' ||
      'partial_refund' ||
      'chargeback' => '$transactionStatus',
      'partial_chargeback' || 'authorize' || 'failure' => '$transactionStatus',
      _ => 'other',
    };
    final key = '$orderId\n$signature\n$kind';
    final now = Clock.now();
    final kept = _confirmations[key];
    if (kept != null && now.difference(kept.at) < confirmationWindow) {
      return kept.event;
    }
    final answer = await status(orderId);
    _confirmations
      ..remove(key)
      ..[key] = (at: now, event: answer);
    while (_confirmations.length > confirmationMemoSize) {
      _confirmations.remove(_confirmations.keys.first);
    }
    return answer;
  }

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

  /// The event in [body]: a notification's, or with [fromApi] the status
  /// API's answer. A field of the wrong type is a 400 in a notification
  /// and a [PaymentGatewayException] in an answer, never a type error.
  PaymentEvent _event(
    Map<String, Object?> body, {
    String prefix = '',
    bool fromApi = false,
  }) {
    String? text(String key) {
      try {
        return notificationText(body, key);
      } on BadRequestHttpException {
        if (!fromApi) {
          rethrow;
        }
        throw PaymentGatewayException(
          'Midtrans status answered a $key that is not text.',
        );
      }
    }

    final status = text('transaction_status') ?? '';
    final fraud = text('fraud_status');
    // Signed: the event id holds it, so an event of one order is never
    // taken for another's.
    final orderId = '${body['order_id']}';
    final transaction = text('transaction_id');
    final time = text('settlement_time') ?? text('transaction_time');
    return PaymentEvent(
      gateway: name,
      // The fraud status is part of the key: a `capture` held for review
      // (`challenge`) is followed by the same `capture` once accepted.
      eventId:
          '$prefix$orderId:${transaction ?? '-'}:$status'
          '${fraud == null ? '' : ':$fraud'}',
      orderId: orderId,
      status: mapStatus(status, fraud),
      amount: num.tryParse('${body['gross_amount']}'),
      currency: text('currency') ?? 'IDR',
      paymentType: text('payment_type'),
      reference: transaction,
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
