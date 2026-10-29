import 'package:daravel/daravel.dart';

import 'payments.dart';

/// `withPayments()` on the application builder.
extension PaymentsApplicationBuilder on ApplicationBuilder {
  /// Reads the gateways' keys ([PaymentsConfig]), binds the
  /// [PaymentManager] and, unless [webhookPath] is null, registers
  /// `POST <webhookPath>/{gateway}` for the gateways' notifications. Add
  /// `CreatePaymentTables()` to `bootstrap/migrations.dart`.
  ApplicationBuilder withPayments({
    String? webhookPath = '/payments/webhook',
    List<Object> middleware = const [],
  }) =>
      withConfig<PaymentsConfig>(PaymentsConfig.fromEnv)
          .withProviders([_PaymentsProvider(webhookPath, middleware)]);
}

final class _PaymentsProvider extends ServiceProvider {
  const _PaymentsProvider(this.webhookPath, this.middleware);

  final String? webhookPath;
  final List<Object> middleware;

  @override
  void register(Container container) => container.singleton<PaymentManager>(
    (c) => PaymentManager(c.make<ConfigRepository>().section<PaymentsConfig>()),
  );

  @override
  void boot(Container container) {
    final path = webhookPath;
    if (path != null) {
      Payment.webhookRoutes(
        container.make<Router>(),
        path: path,
        middleware: middleware,
      );
    }
  }
}
