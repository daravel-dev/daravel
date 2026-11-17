import 'dart:async';
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

  /// The status of [orderId]; when Midtrans does not know the order by its
  /// id, by [reference] (a transaction id), whose answer must still name
  /// [orderId]. Pending when neither is known.
  @override
  Future<PaymentEvent> status(String orderId, {String? reference}) =>
      _readStatus(orderId, allowMissing: true, transactionHint: reference);

  /// Whether [value] can be one segment of a status URL: `.` and `..` are
  /// path steps, not identifiers.
  static bool _segment(String value) => value != '.' && value != '..';

  /// Midtrans' answer that it does not know what was asked for.
  bool _isMissing(ClientResponse response, Map<String, Object?> body) =>
      (response.successful || response.status == 404) &&
      _code(body['status_code']) == '404' &&
      !body.containsKey('transaction_status');

  Future<PaymentEvent> _readStatus(
    String orderId, {
    bool allowMissing = false,
    String? transactionHint,
    String eventPrefix = 'status:',
  }) async {
    if (!_segment(orderId)) {
      throw ArgumentError.value(orderId, 'orderId', 'Not an order id');
    }
    var response = await _http.get(
      '$_api/v2/${Uri.encodeComponent(orderId)}/status',
    );
    var body = apiObject(response, 'Midtrans status');
    if (_isMissing(response, body)) {
      if (transactionHint != null && _segment(transactionHint)) {
        // The reference selects a lookup; the returned order still has to
        // be the authenticated order below.
        response = await _http.get(
          '$_api/v2/${Uri.encodeComponent(transactionHint)}/status',
        );
        body = apiObject(response, 'Midtrans status');
      }
      if (allowMissing && _isMissing(response, body)) {
        return PaymentEvent(
          gateway: name,
          eventId: 'status:$orderId:-:pending',
          orderId: orderId,
          status: PaymentStatus.pending,
          amount: null,
          raw: body,
        );
      }
    }
    final status = body['transaction_status'];
    final transaction = body['transaction_id'];
    final code = _code(body['status_code']);
    final successCode =
        code != null &&
        code.length == 3 &&
        code.startsWith('2') &&
        code.codeUnitAt(1) >= 0x30 &&
        code.codeUnitAt(1) <= 0x39 &&
        code.codeUnitAt(2) >= 0x30 &&
        code.codeUnitAt(2) <= 0x39;
    if (!response.successful ||
        body['order_id'] is! String ||
        body['order_id'] != orderId ||
        status is! String ||
        status.trim().isEmpty ||
        transaction is! String ||
        transaction.trim().isEmpty ||
        !(successCode || (code == '407' && status == 'expire'))) {
      throw PaymentGatewayException(
        'Midtrans status did not provide a complete transaction response.',
        status: response.status,
        body: response.body,
      );
    }
    final event = _event(body, prefix: eventPrefix);
    final amount = event.amount;
    if (event.status == PaymentStatus.paid &&
        (amount == null || !amount.isFinite)) {
      // Nothing to compare with the order: a gateway failure (the webhook
      // is answered 5xx and retried), never paid without a comparison.
      throw PaymentGatewayException(
        'Midtrans status answered a paid transaction without a readable '
        'gross_amount.',
        status: response.status,
        body: response.body,
      );
    }
    return event;
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
    final orderId = notificationText(body, 'order_id');
    if (orderId == null ||
        orderId.trim().isEmpty ||
        orderId.runes.take(256).length > 255 ||
        !_segment(orderId)) {
      throw const BadRequestHttpException(
        'A payment order identifier must contain 1 to 255 characters.',
      );
    }
    final transaction = notificationText(body, 'transaction_id');
    if (transaction == null || transaction.trim().isEmpty) {
      throw const BadRequestHttpException(
        'A Midtrans notification without its transaction_id.',
      );
    }
    if (transaction.runes.take(256).length > 255 || !_segment(transaction)) {
      throw const BadRequestHttpException(
        'A Midtrans transaction_id holds 1 to 255 characters and is not a '
        'path step.',
      );
    }
    for (final field in [
      'transaction_status',
      'fraud_status',
      'currency',
      'payment_type',
      'transaction_time',
      'settlement_time',
    ]) {
      notificationText(body, field);
    }
    return requireAmountWhenPaid(await _confirm(orderId, transaction));
  }

  final Map<String, _StatusLookups> _lookups = {};

  Future<PaymentEvent> _confirm(String orderId, String transactionHint) {
    final existing = _lookups[orderId];
    if (existing != null) {
      final previous = existing.active;
      final next = existing.next ??= SharedResult(() async {
        await previous.done;
        return _readStatus(
          orderId,
          transactionHint: transactionHint,
          eventPrefix: '',
        );
      });
      return next.value;
    }
    final active = SharedResult(
      () => _readStatus(
        orderId,
        transactionHint: transactionHint,
        eventPrefix: '',
      ),
    );
    final state = _StatusLookups(active);
    _lookups[orderId] = state;
    unawaited(active.done.then((_) => _lookupFinished(orderId, state, active)));
    return active.value;
  }

  void _lookupFinished(
    String orderId,
    _StatusLookups state,
    SharedResult<PaymentEvent> completed,
  ) {
    if (!identical(_lookups[orderId], state) ||
        !identical(state.active, completed)) {
      return;
    }
    final next = state.next;
    if (next == null) {
      _lookups.remove(orderId);
      return;
    }
    state.active = next;
    state.next = null;
    unawaited(next.done.then((_) => _lookupFinished(orderId, state, next)));
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

  /// Builds an event from a status API answer. Incorrect field types
  /// become a [PaymentGatewayException].
  PaymentEvent _event(Map<String, Object?> body, {String prefix = ''}) {
    String? text(String key) {
      try {
        return notificationText(body, key);
      } on BadRequestHttpException {
        throw PaymentGatewayException(
          'Midtrans status answered a $key that is not text.',
        );
      }
    }

    final status = text('transaction_status') ?? '';
    final fraud = text('fraud_status');
    // The validated order is included in the event identity.
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
  /// waits). A partial refund is not a status
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

final class _StatusLookups {
  _StatusLookups(this.active);
  SharedResult<PaymentEvent> active;
  SharedResult<PaymentEvent>? next;
}
