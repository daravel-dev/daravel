import 'package:daravel/daravel.dart';

import 'payments.dart';

/// `payment_transactions` (one row per order and gateway) and
/// `payment_webhook_logs` (one row per notification handled: its unique
/// `(gateway, event_id)` makes a webhook apply once).
final class CreatePaymentTables extends Migration {
  const CreatePaymentTables();

  @override
  String get name => '2026_10_29_000000_create_payment_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create(PaymentManager.transactionsTable, (table) {
      table.id();
      table.string('order_id');
      table.string('gateway', length: 32);
      table.string('gateway_reference').nullable();
      table.decimal('amount', precision: 15, scale: 2);
      table.string('currency', length: 3).defaultTo('IDR');
      table.string('status', length: 16);
      table.string('payment_type', length: 64).nullable();
      table.string('payer_email').nullable();
      table.string('payer_name').nullable();
      table.text('metadata').nullable();
      table.timestamp('paid_at').nullable();
      table.timestamps();
      table.unique(['gateway', 'order_id']);
      table.index(['status']);
    });
    await schema.create(PaymentManager.webhookLogTable, (table) {
      table.id();
      table.string('gateway', length: 32);
      table.string('event_id');
      table.string('order_id');
      table.text('payload');
      table.boolean('processed').defaultTo(true);
      table.timestamps();
      table.unique(['gateway', 'event_id']);
      table.index(['gateway', 'order_id']);
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists(PaymentManager.webhookLogTable);
    await schema.dropIfExists(PaymentManager.transactionsTable);
  }
}
