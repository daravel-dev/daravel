import 'package:daravel/daravel.dart';
import 'package:daravel_payments/daravel_payments.dart';

/// `POST /api/checkout` starts a Midtrans Snap payment (MIDTRANS_SERVER_KEY
/// in .env); Midtrans then notifies `POST /payments/webhook/midtrans`, and
/// a verified, first-time `paid` reaches the PaymentPaid listener.
Application createApp() =>
    Application.configure(basePath: '.')
        .withPayments()
        .withMigrations(const [CreatePaymentTables()])
        .withEvents(
          (events) => events.listen<PaymentPaid>(
            (PaymentPaid paid) =>
                Log.info('Paid', {'order': paid.payment.orderId}),
          ),
        )
        .withRouting(
          api: (router) => router.post('/checkout', (Request request) async {
            final checkout = await Payment.checkout(
              PaymentRequest(
                orderId: 'ORDER-${DateTime.now().millisecondsSinceEpoch}',
                amount: 150000,
                items: const [PaymentItem(name: 'Assessment', price: 150000)],
              ),
            );
            return checkout.toJson();
          }),
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
