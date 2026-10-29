import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'types.dart';

/// A gateway that records what it is asked: `Payment.fake()` puts it in
/// place of every gateway, as `Mail.fake()` does for mail.
final class FakePaymentGateway implements PaymentGateway {
  FakePaymentGateway([this.name = 'fake']);

  @override
  final String name;

  final List<PaymentRequest> created = [];
  final Map<String, FakePaymentGateway> _named = {};

  /// Statuses [status] answers, by order id (pending otherwise).
  final Map<String, PaymentStatus> statuses = {};

  /// The fake for gateway [gateway]; all of them share [created].
  FakePaymentGateway named(String gateway) =>
      gateway == name ? this : (_named[gateway] ??= _Shared(gateway, this));

  @override
  Future<PaymentCheckout> create(PaymentRequest request) async {
    created.add(request);
    return PaymentCheckout(
      gateway: name,
      orderId: request.orderId,
      reference: 'fake-${request.orderId}',
      token: 'fake-token-${request.orderId}',
      redirectUrl:
          'https://payments.fake.test/${Uri.encodeComponent(request.orderId)}',
    );
  }

  @override
  Future<PaymentEvent> status(String orderId, {String? reference}) async {
    final status = statuses[orderId] ?? PaymentStatus.pending;
    return event(orderId, status);
  }

  /// A verified event, as if the gateway had sent it: feed it to
  /// `Payment.manager.apply()` to test what the application does.
  PaymentEvent event(
    String orderId,
    PaymentStatus status, {
    num? amount,
    String? eventId,
    String paymentType = 'fake',
  }) => PaymentEvent(
    gateway: name,
    eventId: eventId ?? '$name:$orderId:${status.name}',
    orderId: orderId,
    status: status,
    amount: amount,
    paymentType: paymentType,
    occurredAt: Clock.now(),
  );

  /// Fakes accept any webhook body of the form `{"order_id", "status"}`.
  @override
  Future<PaymentEvent> parseWebhook(Request request) async {
    final body = jsonDecode(utf8.decode(await request.bytes()));
    if (body is! Map<String, Object?>) {
      throw const InvalidPaymentSignatureException();
    }
    return event(
      '${body['order_id']}',
      PaymentStatus.parse('${body['status']}'),
      amount: body['amount'] as num?,
    );
  }

  /// Fails unless a payment was started that [test] accepts.
  void assertCreated([bool Function(PaymentRequest request)? test]) {
    final all = _root.created;
    if (!all.any(test ?? (_) => true)) {
      throw StateError(
        all.isEmpty
            ? 'No payment was started.'
            : 'No started payment matched (${all.length} started).',
      );
    }
  }

  /// Fails when any payment was started.
  void assertNothingCreated() {
    if (_root.created.isNotEmpty) {
      throw StateError('${_root.created.length} payments were started.');
    }
  }

  FakePaymentGateway get _root => this;
}

final class _Shared extends FakePaymentGateway {
  _Shared(super.name, this.root);
  final FakePaymentGateway root;

  @override
  List<PaymentRequest> get created => root.created;

  @override
  Map<String, PaymentStatus> get statuses => root.statuses;

  @override
  FakePaymentGateway get _root => root;
}
