import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'types.dart';

/// Xendit invoices (payment links: virtual accounts, QRIS, e-wallets,
/// retail outlets, cards) and their callbacks, which carry the merchant's
/// verification token in `x-callback-token`.
///
/// This is Xendit's Invoice API (`POST /v2/invoices`), which Xendit
/// calls legacy next to its Payment Sessions; it remains the payment link
/// most Xendit merchants use.
final class XenditGateway implements PaymentGateway {
  XenditGateway({
    required this.secretKey,
    required this.callbackToken,
    this.name = 'xendit',
    this.baseUrl = 'https://api.xendit.co',
  });

  @override
  final String name;

  /// The secret API key (`xnd_development_...` in test mode).
  final String secretKey;

  /// The webhook verification token from the Dashboard's webhook
  /// settings.
  final String callbackToken;
  final String baseUrl;

  PendingRequest get _http =>
      Http.withBasicAuth(secretKey, '').acceptJson().asJson();

  @override
  Future<PaymentCheckout> create(PaymentRequest request) async {
    final customer = request.customer;
    final response = await _http.post(
      '$baseUrl/v2/invoices',
      json: {
        'external_id': request.orderId,
        'amount': request.amount,
        'currency': request.currency.toUpperCase(),
        'description': ?request.description,
        'payer_email': ?customer?.email,
        if (customer != null)
          'customer': {
            'given_names': ?customer.name,
            'email': ?customer.email,
            'mobile_number': ?customer.phone,
          },
        if (request.items.isNotEmpty)
          'items': [
            for (final item in request.items)
              {
                'name': item.name,
                'quantity': item.quantity,
                'price': item.price,
              },
          ],
        if (request.methods.isNotEmpty) 'payment_methods': request.methods,
        'success_redirect_url': ?request.successUrl,
        'failure_redirect_url': ?request.cancelUrl,
        if (request.metadata.isNotEmpty) 'metadata': request.metadata,
      },
    );
    if (!response.successful) {
      throw PaymentGatewayException(
        'Xendit refused the invoice (${response.status}).',
        status: response.status,
        body: response.body,
      );
    }
    final body = jsonDecode(response.body) as Map<String, Object?>;
    return PaymentCheckout(
      gateway: name,
      orderId: request.orderId,
      reference: body['id']! as String,
      redirectUrl: body['invoice_url']! as String,
      raw: body,
    );
  }

  @override
  Future<PaymentEvent> status(String orderId, {String? reference}) async {
    final response = reference != null
        ? await _http.get(
            '$baseUrl/v2/invoices/${Uri.encodeComponent(reference)}',
          )
        : await _http.get(
            '$baseUrl/v2/invoices',
            query: {'external_id': orderId},
          );
    if (!response.successful) {
      throw PaymentGatewayException(
        'Xendit status failed (${response.status}).',
        status: response.status,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body);
    final Map<String, Object?> invoice;
    if (decoded is List) {
      if (decoded.isEmpty) {
        throw PaymentGatewayException('Xendit has no invoice for $orderId.');
      }
      // The newest invoice for the order.
      invoice = decoded.first as Map<String, Object?>;
    } else {
      invoice = decoded as Map<String, Object?>;
    }
    return _event(invoice, prefix: 'status:');
  }

  @override
  Future<PaymentEvent> parseWebhook(Request request) async {
    final token = request.headers.first('x-callback-token');
    if (token == null || !constantTimeEquals(token, callbackToken)) {
      throw const InvalidPaymentSignatureException();
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(await request.bytes()));
    } on FormatException {
      throw const BadRequestHttpException('Not a Xendit callback.');
    }
    if (body is! Map<String, Object?> || body['external_id'] == null) {
      throw const BadRequestHttpException('Not a Xendit invoice callback.');
    }
    return _event(body);
  }

  PaymentEvent _event(Map<String, Object?> invoice, {String prefix = ''}) {
    final status = '${invoice['status']}';
    final paidAt = invoice['paid_at'] as String?;
    return PaymentEvent(
      gateway: name,
      eventId: '$prefix${invoice['id']}:$status',
      orderId: '${invoice['external_id']}',
      status: mapStatus(status),
      amount: (invoice['paid_amount'] ?? invoice['amount']) as num?,
      currency: invoice['currency'] as String?,
      paymentType:
          (invoice['payment_channel'] ?? invoice['payment_method']) as String?,
      reference: invoice['id'] as String?,
      occurredAt: paidAt == null ? null : DateTime.tryParse(paidAt),
      raw: invoice,
    );
  }

  /// An invoice's `status` as a [PaymentStatus]: `PAID` and `SETTLED`
  /// are paid.
  static PaymentStatus? mapStatus(String status) => switch (status) {
    'PAID' || 'SETTLED' => PaymentStatus.paid,
    'PENDING' => PaymentStatus.pending,
    'EXPIRED' => PaymentStatus.expired,
    _ => null,
  };
}
