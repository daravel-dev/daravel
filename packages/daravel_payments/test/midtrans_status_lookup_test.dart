import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_payments/daravel_payments.dart';
import 'package:test/test.dart';

const _key = 'SB-Mid-server-TEST';

final class _Headers implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Map<String, Object?> body, this.statusCode)
    : bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
  final Uint8List bytes;
  @override
  final int statusCode;
  @override
  int get contentLength => bytes.length;
  @override
  final headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(this.url, this.client);
  final Uri url;
  final _Client client;
  final result = Completer<HttpClientResponse>();
  @override
  final headers = _Headers();
  @override
  Future<HttpClientResponse> close() => result.future;
  void answer(Map<String, Object?> body, {int status = 200}) {
    if (!result.isCompleted) {
      client.active--;
      result.complete(_Response(body, status));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Client implements HttpClient {
  final requests = <_Request>[];
  int active = 0;
  int peak = 0;
  @override
  Duration idleTimeout = Duration.zero;
  @override
  Duration? connectionTimeout;
  @override
  int? maxConnectionsPerHost;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    active++;
    if (active > peak) peak = active;
    final request = _Request(url, this);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    for (final request in requests) {
      request.answer(const {'status_code': '500'}, status: 500);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> _status(
  String state, {
  String order = 'ORDER',
  String code = '200',
}) => {
  'order_id': order,
  'transaction_id': 'tx-$order',
  'transaction_status': state,
  'status_code': code,
  'gross_amount': '100.00',
  'currency': 'IDR',
};

Request _notification({
  String order = 'ORDER',
  String transaction = 'tx-ORDER',
  String state = 'failure',
}) {
  final body = <String, Object?>{
    'order_id': order,
    'transaction_id': transaction,
    'transaction_status': state,
    'status_code': '201',
    'gross_amount': '100.00',
  };
  body['signature_key'] = MidtransGateway(serverKey: _key).signatureFor(body);
  return Request.fake(method: 'POST', json: body);
}

// Every caller reaches its next controlled response before this event turn.
Future<void> _settleCallers() => Future<void>(() {});

void main() {
  late Application app;
  late _Client client;
  late MidtransGateway gateway;
  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    client = _Client();
    app.container.instance<HttpClientFactory>(
      HttpClientFactory(clientFactory: () => client),
    );
    gateway = MidtransGateway(serverKey: _key);
  });
  tearDown(() async {
    client.close(force: true);
    await app.shutdown();
    Container.setRoot(null);
  });
  Future<PaymentEvent> deliver({
    String order = 'ORDER',
    String transaction = 'tx-ORDER',
  }) {
    final result = app.run(
      () => gateway.parseWebhook(
        _notification(order: order, transaction: transaction),
      ),
    );
    result.ignore();
    return result;
  }

  test('each sequential notification obtains the current status', () async {
    for (final state in ['pending', 'settlement', 'refund']) {
      final pending = deliver();
      await _settleCallers();
      expect(client.requests.last.url.path, '/v2/ORDER/status');
      client.requests.last.answer(_status(state));
      final event = await pending;
      expect(event.status, MidtransGateway.mapStatus(state, null));
      expect(event.raw['transaction_status'], state);
    }
    expect(client.requests, hasLength(3));
  });

  test('pending notifications obtain the status response', () async {
    final pending = app.run(
      () => gateway.parseWebhook(_notification(state: 'pending')),
    );
    await _settleCallers();
    expect(client.requests, hasLength(1));
    client.requests.single.answer(_status('settlement'));
    expect((await pending).status, PaymentStatus.paid);
  });

  final invalid = <(String, Object?)>[
    ('transaction_status', null),
    ('transaction_status', ''),
    ('transaction_status', '  '),
    ('transaction_status', 123),
    ('transaction_id', null),
    ('transaction_id', ''),
    ('transaction_id', 123),
    ('order_id', 'OTHER'),
    ('order_id', 123),
    ('status_code', '401'),
    ('status_code', '500'),
    ('status_code', '404'),
    ('status_code', '407'),
  ];
  for (final (field, value) in invalid) {
    test('status response validates $field = $value', () async {
      final pending = deliver();
      final checked = expectLater(
        pending,
        throwsA(isA<PaymentGatewayException>()),
      );
      await _settleCallers();
      final body = _status('pending')..[field] = value;
      client.requests.single.answer(body);
      await checked;
    });
  }

  test('a second lookup must still match the authenticated order', () async {
    final pending = deliver(transaction: 'reference');
    final checked = expectLater(
      pending,
      throwsA(isA<PaymentGatewayException>()),
    );
    await _settleCallers();
    client.requests[0].answer(const {'status_code': '404'});
    await _settleCallers();
    client.requests[1].answer(_status('settlement', order: 'OTHER'));
    await checked;
  });

  test('two missing lookup answers are a gateway failure', () async {
    final pending = deliver(transaction: 'reference');
    final checked = expectLater(
      pending,
      throwsA(isA<PaymentGatewayException>()),
    );
    await _settleCallers();
    client.requests[0].answer(const {'status_code': '404'});
    await _settleCallers();
    client.requests[1].answer(const {'status_code': '404'});
    await checked;
  });

  test('arrivals during a lookup share the next lookup, in order', () async {
    final first = deliver();
    await _settleCallers();
    final batch = [for (var i = 0; i < 30; i++) deliver()];
    await _settleCallers();
    expect(client.requests, hasLength(1));
    client.requests[0].answer(_status('pending'));
    expect((await first).status, PaymentStatus.pending);
    await _settleCallers();
    expect(client.requests, hasLength(2));
    final third = deliver();
    await _settleCallers();
    expect(client.requests, hasLength(2));
    client.requests[1].answer(_status('settlement'));
    expect(
      (await Future.wait(batch))
          .every((event) => event.status == PaymentStatus.paid),
      isTrue,
    );
    await _settleCallers();
    expect(client.requests, hasLength(3));
    client.requests[2].answer(_status('refund'));
    expect((await third).status, PaymentStatus.refunded);
    expect(client.peak, 1);
  });

  test('lookup failures reach every request scope', () async {
    final first = deliver();
    final firstCheck = expectLater(
      first,
      throwsA(isA<PaymentGatewayException>()),
    );
    await _settleCallers();
    final waiters = [deliver(), deliver()];
    final checks = [
      for (final waiter in waiters)
        expectLater(waiter, throwsA(isA<PaymentGatewayException>())),
    ];
    await _settleCallers();
    for (final request in client.requests.toList()) {
      request.answer(const {'status_code': '500'}, status: 500);
    }
    await firstCheck;
    await _settleCallers();
    for (final request in client.requests.toList()) {
      request.answer(const {'status_code': '500'}, status: 500);
    }
    await Future.wait(checks).timeout(const Duration(seconds: 2));
    expect(client.requests, hasLength(2));
    expect(client.peak, 1);
  });

  test(
    'an alternate transaction lookup still returns the requested order',
    () async {
      final pending = deliver(transaction: 'dana-reference');
      await _settleCallers();
      client.requests[0].answer(const {'status_code': '404'});
      await _settleCallers();
      expect(client.requests[1].url.path, '/v2/dana-reference/status');
      client.requests[1].answer(_status('settlement'));
      expect((await pending).status, PaymentStatus.paid);
    },
  );

  test('an expired status response retains its documented code', () async {
    final pending = deliver();
    await _settleCallers();
    client.requests[0].answer(_status('expire', code: '407'));
    expect((await pending).status, PaymentStatus.expired);
  });

  test(
    'status for a missing transaction remains pending for direct callers',
    () async {
      final pending = app.run(() => gateway.status('ORDER'));
      await _settleCallers();
      client.requests[0].answer(const {'status_code': '404'});
      expect((await pending).status, PaymentStatus.pending);
    },
  );

  test('the applied event is the status response, whatever the '
      'notification carries', () async {
    final body = <String, Object?>{
      'order_id': 'ORDER',
      'transaction_id': 'tx-notified',
      'transaction_status': 'settlement',
      'fraud_status': 'accept',
      'status_code': '201',
      'gross_amount': '100.00',
      'currency': 'USD',
      'payment_type': 'gopay',
      'transaction_time': '2030-01-01 00:00:00',
    };
    body['signature_key'] = gateway.signatureFor(body);
    final pending = app.run(
      () => gateway.parseWebhook(Request.fake(method: 'POST', json: body)),
    );
    await _settleCallers();
    final answer = _status('pending')
      ..['payment_type'] = 'bank_transfer'
      ..['transaction_time'] = '2026-01-01 10:00:00';
    client.requests.single.answer(answer);
    final event = await pending;
    expect(event.status, PaymentStatus.pending);
    expect(event.eventId, 'ORDER:tx-ORDER:pending');
    expect(event.reference, 'tx-ORDER');
    expect(event.currency, 'IDR');
    expect(event.paymentType, 'bank_transfer');
    expect(event.occurredAt, DateTime.utc(2026, 1, 1, 3));
    expect(event.raw, answer);
  });

  group('a transaction id or order id that cannot name a lookup', () {
    final refused = {
      '.': '.',
      '..': '..',
      '256 characters': 'x' * 256,
      '256 astral characters': '\u{1F600}' * 256,
    };
    for (final MapEntry(key: name, value: transaction) in refused.entries) {
      test('transaction_id $name is refused (400) before any lookup', () async {
        await expectLater(
          deliver(transaction: transaction),
          throwsA(isA<BadRequestHttpException>()),
        );
        expect(client.requests, isEmpty);
      });
    }

    test('255 characters is a transaction_id', () async {
      final pending = deliver(transaction: 'x' * 255);
      await _settleCallers();
      expect(client.requests, hasLength(1));
      client.requests.single.answer(_status('pending'));
      expect((await pending).status, PaymentStatus.pending);
    });

    for (final order in ['.', '..']) {
      test('order_id "$order" is refused (400) before any lookup', () async {
        await expectLater(
          deliver(order: order),
          throwsA(isA<BadRequestHttpException>()),
        );
        expect(client.requests, isEmpty);
      });
    }

    test('a reference of "." or ".." is not looked up', () async {
      for (final reference in ['.', '..']) {
        final pending = app.run(
          () => gateway.status('ORDER', reference: reference),
        );
        await _settleCallers();
        client.requests.last.answer(const {'status_code': '404'});
        expect((await pending).status, PaymentStatus.pending);
      }
      expect(client.requests.map((r) => r.url.path), [
        '/v2/ORDER/status',
        '/v2/ORDER/status',
      ]);
    });
  });

  group('status by reference', () {
    test('an order Midtrans does not know by its id is looked up by its '
        'reference', () async {
      final pending = app.run(
        () => gateway.status('ORDER', reference: 'tx-saved'),
      );
      await _settleCallers();
      client.requests[0].answer(const {'status_code': '404'}, status: 404);
      await _settleCallers();
      expect(client.requests[1].url.path, '/v2/tx-saved/status');
      client.requests[1].answer(_status('settlement'));
      final event = await pending;
      expect(event.status, PaymentStatus.paid);
      expect(event.amount, 100);
    });

    test('the reference answer must name the order', () async {
      final pending = app.run(
        () => gateway.status('ORDER', reference: 'tx-saved'),
      );
      final checked = expectLater(
        pending,
        throwsA(isA<PaymentGatewayException>()),
      );
      await _settleCallers();
      client.requests[0].answer(const {'status_code': '404'});
      await _settleCallers();
      client.requests[1].answer(_status('settlement', order: 'OTHER'));
      await checked;
    });

    test('pending when neither is known', () async {
      final pending = app.run(
        () => gateway.status('ORDER', reference: 'tx-saved'),
      );
      await _settleCallers();
      client.requests[0].answer(const {'status_code': '404'});
      await _settleCallers();
      client.requests[1].answer(const {'status_code': '404'});
      expect((await pending).status, PaymentStatus.pending);
    });
  });

  group('a paid status answer without a readable gross_amount', () {
    for (final amount in <Object?>[null, 'NaN', 'Infinity', 'many']) {
      test('$amount is a gateway failure, for notifications and for '
          'status()', () async {
        final answer = _status('settlement');
        if (amount == null) {
          answer.remove('gross_amount');
        } else {
          answer['gross_amount'] = amount;
        }
        final notified = deliver();
        final checkedNotified = expectLater(
          notified,
          throwsA(isA<PaymentGatewayException>()),
        );
        await _settleCallers();
        client.requests.last.answer(answer);
        await checkedNotified;

        final direct = app.run(() => gateway.status('ORDER'));
        final checkedDirect = expectLater(
          direct,
          throwsA(isA<PaymentGatewayException>()),
        );
        await _settleCallers();
        client.requests.last.answer(answer);
        await checkedDirect;
      });
    }
  });

  group('a batch of lookups for one order', () {
    const missing = {'status_code': '404'};

    /// What each delivery ended with: its status, or the error's type.
    Future<String> settle(Future<PaymentEvent> delivery) => delivery.then(
      (event) => event.status!.name,
      onError: (Object error) => '${error.runtimeType}',
    );

    test('each notification waiting with its own transaction id gets the '
        'answer for that id', () async {
      final first = settle(deliver(transaction: 'tx-unknown-1'));
      await _settleCallers();
      final second = settle(deliver(transaction: 'tx-unknown-2'));
      final third = settle(deliver(transaction: 'tx-ORDER'));
      await _settleCallers();
      client.requests[0].answer(missing);
      await _settleCallers();
      expect(client.requests[1].url.path, '/v2/tx-unknown-1/status');
      client.requests[1].answer(missing);
      await _settleCallers();
      // The waiting batch: the order once, then each id in turn.
      expect(client.requests[2].url.path, '/v2/ORDER/status');
      client.requests[2].answer(missing);
      await _settleCallers();
      expect(client.requests[3].url.path, '/v2/tx-unknown-2/status');
      client.requests[3].answer(missing);
      await _settleCallers();
      expect(client.requests[4].url.path, '/v2/tx-ORDER/status');
      client.requests[4].answer(_status('settlement'));
      expect(await first, 'PaymentGatewayException');
      expect(await second, 'PaymentGatewayException');
      expect(await third, 'paid');
      expect(client.requests, hasLength(5));
    });

    test('a waiting batch takes ${MidtransGateway.hintsPerBatch} distinct '
        'transaction ids; another one is answered 429 with Retry-After, '
        'and the batch makes at most 1 + '
        '${MidtransGateway.hintsPerBatch} calls', () async {
      final running = settle(deliver(transaction: 'tx-running'));
      await _settleCallers();
      final waiting = [
        for (var i = 0; i < MidtransGateway.hintsPerBatch; i++)
          settle(deliver(transaction: 'tx-w$i')),
      ];
      // The same id again joins without taking a place.
      final again = settle(deliver(transaction: 'tx-w0'));
      final refused = deliver(transaction: 'tx-one-more');
      await expectLater(
        refused,
        throwsA(
          isA<HttpException>()
              .having((e) => e.status, 'status', 429)
              .having((e) => e.headers['Retry-After'], 'Retry-After', '1'),
        ),
      );
      await _settleCallers();
      client.requests[0].answer(missing);
      await _settleCallers();
      client.requests[1].answer(missing);
      for (var i = 0; i <= MidtransGateway.hintsPerBatch; i++) {
        await _settleCallers();
        client.requests[2 + i].answer(missing);
      }
      await _settleCallers();
      expect(await running, 'PaymentGatewayException');
      expect(await Future.wait([...waiting, again]), [
        for (var i = 0; i <= MidtransGateway.hintsPerBatch; i++)
          'PaymentGatewayException',
      ]);
      expect(client.requests, hasLength(2 + 1 + MidtransGateway.hintsPerBatch));
    });

    test('a transaction id that is the order id adds no lookup', () async {
      final pending = settle(deliver(transaction: 'ORDER'));
      await _settleCallers();
      client.requests.single.answer(missing);
      expect(await pending, 'PaymentGatewayException');
      expect(client.requests, hasLength(1));
    });

    /// After a batch ended, nothing of it is left: the next notification
    /// is looked up at once, and its waiting batch has every place free.
    Future<void> expectNothingLeft() async {
      final before = client.requests.length;
      final next = settle(deliver(transaction: 'tx-after'));
      await _settleCallers();
      expect(client.requests, hasLength(before + 1), reason: 'looked up');
      final waiting = [
        for (var i = 0; i < MidtransGateway.hintsPerBatch; i++)
          settle(deliver(transaction: 'tx-free-$i')),
      ];
      client.requests.last.answer(_status('pending'));
      expect(await next, 'pending');
      await _settleCallers();
      client.requests.last.answer(_status('pending'));
      expect(await Future.wait(waiting), [
        for (var i = 0; i < MidtransGateway.hintsPerBatch; i++) 'pending',
      ]);
    }

    test('nothing is left once a lookup failed', () async {
      final failed = settle(deliver(transaction: 'tx-a'));
      await _settleCallers();
      client.requests[0].answer(const {'status_code': '500'}, status: 500);
      expect(await failed, 'PaymentGatewayException');
      await expectNothingLeft();
    });

    test(
      'nothing is left once every transaction id of a batch failed',
      () async {
        final running = settle(deliver(transaction: 'tx-a'));
        await _settleCallers();
        final waiting = [
          for (var i = 0; i < MidtransGateway.hintsPerBatch; i++)
            settle(deliver(transaction: 'tx-f$i')),
        ];
        client.requests[0].answer(missing);
        await _settleCallers();
        client.requests[1].answer(missing);
        for (var i = 0; i <= MidtransGateway.hintsPerBatch; i++) {
          await _settleCallers();
          client.requests.last.answer(missing);
        }
        expect(await running, 'PaymentGatewayException');
        for (final result in await Future.wait(waiting)) {
          expect(result, 'PaymentGatewayException');
        }
        await expectNothingLeft();
      },
    );

    test('a notification that stops waiting (its request timed out) leaves '
        'the lookup to the others, and nothing is left after it', () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final running = settle(deliver(transaction: 'tx-running'));
        await _settleCallers();
        // Both wait in the next batch, each in a request scope of its own.
        final leaving = deliver(transaction: 'tx-shared')
            .timeout(const Duration(milliseconds: 1));
        final staying = deliver(transaction: 'tx-shared');
        await expectLater(leaving, throwsA(isA<TimeoutException>()));
        client.requests[0].answer(missing);
        await _settleCallers();
        client.requests[1].answer(missing);
        expect(await running, 'PaymentGatewayException');
        await _settleCallers();
        client.requests[2].answer(missing);
        await _settleCallers();
        expect(client.requests[3].url.path, '/v2/tx-shared/status');
        client.requests[3].answer(_status('settlement'));
        expect((await staying).status, PaymentStatus.paid);
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty, reason: 'no error left unhandled');
      await expectNothingLeft();
    });
  });
}
