import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class PaymentGateway {
  PaymentGateway(this.env);
  final Env env;
}

final class OrderService {
  OrderService(this.gateway, this.logger);
  final PaymentGateway gateway;
  final Logger logger;
}

/// One per request.
final class RequestAudit {
  RequestAudit(this.request);
  final Request request;
}

final class OrderController {
  OrderController({OrderService? orders}) : orders = orders ?? inject();
  final OrderService orders;
}

final class ReportsProvider extends ServiceProvider {
  const ReportsProvider();

  static OrderService? seenAtBoot;

  @override
  void register(Container container) {}

  @override
  Future<void> boot(Container container) async {
    seenAtBoot = container<OrderService>();
  }
}

void main() {
  test('Container.call infers the type from the parameter', () {
    final container = Container()
      ..instance<Env>(Env.fromMap(const {'APP_NAME': 'x'}))
      ..instance<Logger>(Logger())
      ..singleton((c) => PaymentGateway(c()))
      ..singleton((c) => OrderService(c(), c()));
    final orders = container<OrderService>();
    expect(orders.gateway.env.string('APP_NAME', ''), 'x');
    expect(container<OrderService>(), same(orders));
  });

  group('withBindings and inject()', () {
    late Application app;
    late Directory base;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_di');
      app = Application.configure(basePath: base.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withBindings((c) {
            c
              ..singleton((c) => PaymentGateway(c()))
              ..singleton((c) => OrderService(c(), c()))
              ..scoped((c) => RequestAudit(c()));
          })
          .withProviders([const ReportsProvider()])
          .withRouting(
            api: (r) => r.get('/audit', (request) {
              final controller = OrderController();
              final audit = inject<RequestAudit>();
              return {
                'same_request': identical(audit.request, request),
                'same_instance': identical(audit, inject<RequestAudit>()),
                'audit': identityHashCode(audit),
                'orders': identityHashCode(controller.orders),
                'missing': maybeInject<HttpClientFake>() == null,
              };
            }),
          )
          .create();
      await app.boot();
    });
    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    test('providers see the bindings, controllers resolve them', () async {
      expect(ReportsProvider.seenAtBoot, isA<OrderService>());
      final first = await app.handle(Request.fake(path: '/api/audit'));
      final second = await app.handle(Request.fake(path: '/api/audit'));
      final a = await first.bodyText();
      final b = await second.bodyText();
      expect(a, contains('"same_request":true'));
      expect(a, contains('"same_instance":true'));
      expect(a, contains('"missing":true'));
      String field(String body, String key) =>
          RegExp('"$key":(\\d+)').firstMatch(body)!.group(1)!;
      // Scoped: a new audit per request; singleton: the same service.
      expect(field(a, 'audit'), isNot(field(b, 'audit')));
      expect(field(a, 'orders'), field(b, 'orders'));
    });

    test('an injected default stays replaceable in unit tests', () {
      final fake = OrderService(
        PaymentGateway(Env.fromMap(const <String, String>{})),
        Logger(),
      );
      expect(OrderController(orders: fake).orders, same(fake));
    });
  });
}

/// A type nothing binds, for maybeInject.
final class HttpClientFake {}
