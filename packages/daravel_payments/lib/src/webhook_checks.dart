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
/// mode carries the `currency` of its line items.
PaymentEvent requireAmountWhenPaid(PaymentEvent event) {
  final currency = event.currency;
  if (event.status == PaymentStatus.paid &&
      (event.amount == null || currency == null || currency.trim().isEmpty)) {
    throw BadRequestHttpException(
      'A paid ${event.gateway} notification without a readable amount and '
      'currency.',
    );
  }
  return event;
}
