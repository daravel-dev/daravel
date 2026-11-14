import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'types.dart';

/// The JSON object a gateway's API answered with. Anything else (an HTML
/// page from a proxy during an outage, an array, an empty body) is a
/// [PaymentGatewayException], answered 5xx, so nothing is applied and the
/// gateway sends its notification again.
Map<String, Object?> apiObject(ClientResponse response, String call) {
  Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! Map<String, Object?>) {
    throw PaymentGatewayException(
      '$call answered ${response.status} without a JSON object.',
      status: response.status,
      body: response.body,
    );
  }
  return decoded;
}

/// The text field [key] of a notification's [body]: null when absent, a
/// 400 when it holds another type (a notification whose signature does not
/// cover the field can still carry one).
String? notificationText(Map<String, Object?> body, String key) =>
    switch (body[key]) {
      null => null,
      final String text => text,
      _ => throw BadRequestHttpException(
        'The notification field $key is not text.',
      ),
    };

/// [event], read from a gateway's webhook, refused with a 400 when it says
/// the payment is paid without an amount and a currency that could be
/// read: `PaymentManager.apply` compares only what an event carries, so a
/// built-in gateway never hands it a paid event without them. Events an
/// application builds itself are not checked here.
///
/// The gateways send both: Xendit's invoice callback requires `amount` and
/// `currency` (`InvoiceCallback`, xendit-php 7.0.0), Midtrans' amount is
/// `gross_amount` in IDR, and a Stripe Checkout Session created in payment
/// mode carries the `currency` of its line items. Such a session (or
/// invoice) never becomes `paid` through a webhook: the gateway is
/// answered 400 and retries, and the refusal is logged as a warning with
/// the event id and the reason, never the payload.
PaymentEvent requireAmountWhenPaid(PaymentEvent event) {
  final currency = event.currency;
  final amount = event.amount;
  if (event.status == PaymentStatus.paid &&
      (amount == null ||
          !amount.isFinite ||
          currency == null ||
          currency.trim().isEmpty)) {
    final reason = amount == null || !amount.isFinite
        ? 'no readable amount'
        : 'no readable currency';
    Container.currentOrNull?.tryMake<Logger>()?.warning(
      'Payment notification refused: paid, $reason',
      {
        'gateway': event.gateway,
        'event_id': event.eventId,
        'order_id': event.orderId,
      },
    );
    throw BadRequestHttpException(
      'A paid ${event.gateway} notification without a readable amount and '
      'currency.',
    );
  }
  return event;
}
