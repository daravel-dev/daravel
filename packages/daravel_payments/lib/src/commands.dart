import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

import 'payments.dart';

/// The `payment:*` commands, for `bootstrap/commands.dart`.
const List<CommandFactory> paymentCommands = [PaymentCheckCommand.new];

/// `payment:check <order_id>`: asks the gateway where the payment is and
/// applies the answer, for a webhook that never arrived.
final class PaymentCheckCommand extends DaravelCommand {
  PaymentCheckCommand(super.createApp);

  @override
  String get name => 'payment:check';

  @override
  String get description =>
      'Ask the gateway about a payment and bring the record up to date.';

  @override
  String get invocation => 'dartisan payment:check <order_id>';

  @override
  Future<int> run() => withApp((app) async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Give the order id: dartisan payment:check ORDER-42');
    }
    final orderId = rest.first;
    final before = await Payment.find(orderId);
    if (before == null) {
      stderr.writeln('No payment recorded for $orderId.');
      return 1;
    }
    final outcome = await Payment.manager.reconcile(orderId);
    final after = await Payment.find(orderId);
    stdout.writeln(
      '$orderId (${before.gateway}): ${before.status.name} → '
      '${after!.status.name} (${outcome.name})',
    );
    return 0;
  });
}
