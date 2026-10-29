/// Payments for Daravel (Blueprint #40): Midtrans (Snap), Xendit
/// (invoices) and Stripe (Checkout) behind one API, with webhooks verified
/// and applied exactly once, amounts checked, and events after commit.
///
/// ```dart
/// Application.configure(basePath: '.').withPayments()
/// final checkout = await Payment.checkout(
///   const PaymentRequest(orderId: 'ORDER-42', amount: 150000),
/// );
/// ```
library;

export 'src/fake.dart';
export 'src/midtrans.dart';
export 'src/migration.dart';
export 'src/payments.dart';
export 'src/setup.dart';
export 'src/stripe.dart';
export 'src/types.dart';
export 'src/xendit.dart';
