import 'package:daravel/daravel.dart';

import 'types.dart';

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
  if (event.status == PaymentStatus.paid &&
      (event.amount == null || currency == null || currency.trim().isEmpty)) {
    final reason = event.amount == null
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
