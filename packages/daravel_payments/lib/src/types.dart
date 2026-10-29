import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

/// Where a payment is. Only some moves are possible (see [canMoveTo]): a
/// late `pending` notification never takes a paid order back.
enum PaymentStatus {
  pending,
  paid,
  failed,
  expired,
  refunded;

  /// Whether a payment in this status may become [next]. A paid payment
  /// can only be refunded; failed and expired ones can still be paid
  /// (a gateway may settle after reporting a failure); refunded is final.
  bool canMoveTo(PaymentStatus next) => switch (this) {
    pending => next != pending,
    paid => next == refunded,
    failed || expired => next == paid,
    refunded => false,
  };

  static PaymentStatus parse(String value) =>
      values.firstWhere((s) => s.name == value);
}

/// A line of the order.
final class PaymentItem {
  const PaymentItem({
    required this.name,
    required this.price,
    this.quantity = 1,
    this.id,
  });

  final String? id;
  final String name;

  /// The unit price, in the currency's main unit (rupiah, dollars).
  final num price;
  final int quantity;
}

/// Who pays.
final class PaymentCustomer {
  const PaymentCustomer({this.name, this.email, this.phone});

  final String? name;
  final String? email;
  final String? phone;
}

/// What to charge.
final class PaymentRequest {
  const PaymentRequest({
    required this.orderId,
    required this.amount,
    this.currency = 'IDR',
    this.items = const [],
    this.customer,
    this.description,
    this.successUrl,
    this.cancelUrl,
    this.methods = const [],
    this.metadata = const {},
  });

  /// Your unique id of the order; the gateways key everything on it.
  final String orderId;

  /// The total, in the currency's main unit: `150000` rupiah, `19.99`
  /// dollars. Each gateway converts it as its API expects.
  final num amount;

  /// ISO 4217, upper case.
  final String currency;
  final List<PaymentItem> items;
  final PaymentCustomer? customer;
  final String? description;

  /// Where the customer returns after paying, or after giving up.
  final String? successUrl;
  final String? cancelUrl;

  /// Payment methods to offer, in the gateway's names (`qris`,
  /// `bca_va`, `gopay` for Midtrans; `QRIS`, `BCA` for Xendit).
  final List<String> methods;
  final Map<String, Object?> metadata;
}

/// A payment started at a gateway: where to send the customer.
final class PaymentCheckout {
  const PaymentCheckout({
    required this.gateway,
    required this.orderId,
    required this.reference,
    required this.redirectUrl,
    this.token,
    this.raw = const {},
  });

  final String gateway;
  final String orderId;

  /// The gateway's id of the payment (Snap token, invoice id, Checkout
  /// Session id).
  final String reference;

  /// The page the customer pays on.
  final String redirectUrl;

  /// A token for the gateway's own client widget (Midtrans Snap.js).
  final String? token;
  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => {
    'gateway': gateway,
    'order_id': orderId,
    'reference': reference,
    'redirect_url': redirectUrl,
    'token': ?token,
  };
}

/// What a gateway says about a payment, from a verified webhook or a
/// status query.
final class PaymentEvent {
  const PaymentEvent({
    required this.gateway,
    required this.eventId,
    required this.orderId,
    required this.status,
    required this.amount,
    this.currency,
    this.paymentType,
    this.reference,
    this.occurredAt,
    this.raw = const {},
  });

  final String gateway;

  /// Unique per notification: what the idempotency log keys on.
  final String eventId;
  final String orderId;

  /// The status the gateway reports, or `null` for a notification that
  /// says nothing about it (an event this package does not follow).
  final PaymentStatus? status;

  /// The amount the gateway reports, in the main unit.
  final num? amount;
  final String? currency;
  final String? paymentType;
  final String? reference;
  final DateTime? occurredAt;
  final Map<String, Object?> raw;
}

/// A webhook whose signature or token does not match: never from the
/// gateway, answered 401.
final class InvalidPaymentSignatureException extends HttpException {
  const InvalidPaymentSignatureException([
    String message = 'Invalid payment notification signature.',
  ]) : super(401, message);
}

/// A gateway refused a request or could not be reached.
final class PaymentGatewayException extends DaravelException {
  const PaymentGatewayException(super.message, {this.status, this.body});

  final int? status;
  final String? body;
}

/// One payment gateway.
abstract interface class PaymentGateway {
  /// The name it is registered under (`midtrans`, `xendit`, `stripe`).
  String get name;

  /// Starts a payment and returns where the customer pays.
  Future<PaymentCheckout> create(PaymentRequest request);

  /// Asks the gateway where the payment is now (reconciliation).
  /// [reference] is the [PaymentCheckout.reference] when the gateway needs
  /// it rather than the order id.
  Future<PaymentEvent> status(String orderId, {String? reference});

  /// Verifies a webhook ([InvalidPaymentSignatureException] when it is
  /// not from the gateway) and reads it.
  Future<PaymentEvent> parseWebhook(Request request);
}

/// Hex SHA-512 of [text].
String sha512Hex(String text) => sha512.convert(utf8.encode(text)).toString();

/// Hex HMAC-SHA256 of [message] with [key].
String hmacSha256Hex(String key, String message) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(message)).toString();

/// Currencies without minor units, as Stripe lists them: their amounts
/// are sent as they are; others are multiplied by 100.
const Set<String> zeroDecimalCurrencies = {
  'BIF', 'CLP', 'DJF', 'GNF', 'JPY', 'KMF', 'KRW', 'MGA', //
  'PYG', 'RWF', 'UGX', 'VND', 'VUV', 'XAF', 'XOF', 'XPF',
};

/// [amount] in the smallest unit of [currency].
int toMinorUnits(num amount, String currency) =>
    zeroDecimalCurrencies.contains(currency.toUpperCase())
    ? amount.round()
    : (amount * 100).round();

/// [minor] back in the main unit of [currency].
num fromMinorUnits(int minor, String currency) =>
    zeroDecimalCurrencies.contains(currency.toUpperCase())
    ? minor
    : minor / 100;
