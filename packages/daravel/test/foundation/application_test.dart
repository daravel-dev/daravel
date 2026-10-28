import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Clock {
  Clock(this.label);
  final String label;
}

final class Cache {
  Cache(this.clock);
  final Clock clock;
}

final class _ClockProvider extends ServiceProvider {
  const _ClockProvider(this.log);
  final List<String> log;

  @override
  void register(Container container) {
    log.add('clock.register');
    container.singleton<Clock>((_) => Clock('wall'));
  }

  @override
  Future<void> boot(Container container) async {
    log.add('clock.boot');
  }
}

final class _CacheProvider extends DeferredServiceProvider {
  const _CacheProvider(this.log);
  final List<String> log;

  @override
  List<Type> get provides => const [Cache];

  @override
  void registerDeferred(Container container) {
    log.add('cache.register');
    container.singleton<Cache>((c) => Cache(c.make<Clock>()));
  }

  @override
  Future<void> boot(Container container) async {
    log.add('cache.boot');
  }
}

ApplicationBuilder _builder(Map<String, String> env) =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env});

void main() {
  tearDown(() => Container.setRoot(null));

  test(
    'providers register before any boot; deferred ones register lazily',
    () async {
      final log = <String>[];
      final app = _builder({})
          .withProviders([_CacheProvider(log), _ClockProvider(log)])
          .create();
      await app.boot();

      expect(log, ['clock.register', 'clock.boot']);
      expect(app.container.bound<Cache>(), isTrue);

      final cache = app.container.make<Cache>();
      expect(log, ['clock.register', 'clock.boot', 'cache.register']);
      expect(cache.clock.label, 'wall');
      expect(identical(cache, app.container.make<Cache>()), isTrue);
      await app.shutdown();
    },
  );

  test('boot is idempotent and freezes configuration', () async {
    final app = _builder({'APP_NAME': 'Frozen'}).create();
    await Future.wait([app.boot(), app.boot()]);
    expect(app.booted, isTrue);
    expect(app.config.frozen, isTrue);
    expect(
      () => app.config.set('app.name', 'x'),
      throwsA(isA<ConfigException>()),
    );
    await app.run(() async => expect(Config.get<String>('app.name'), 'Frozen'));
    await app.shutdown();
  });

  test('shutdown is safe before boot, as a failed setUp leaves it', () async {
    // A test's tearDown shuts down an application whose boot timed out or
    // threw: that must not hide the real failure behind its own error.
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .create();
    await app.shutdown();
    expect(app.booted, isFalse);
  });

  test(
    'debug mode in production aborts the boot unless explicitly allowed',
    () async {
      final strict = _builder({'APP_ENV': 'production', 'APP_DEBUG': 'true'})
          .create();
      await expectLater(strict.boot(), throwsA(isA<ConfigException>()));

      final allowed = _builder({
        'APP_ENV': 'production',
        'APP_DEBUG': 'true',
        'APP_ALLOW_DEBUG_IN_PRODUCTION': 'true',
      }).create();
      await allowed.boot();
      expect(allowed.exceptions.debug, isTrue);
      await allowed.shutdown();
    },
  );

  test('APP_KEY and DB_CONNECTION are validated', () async {
    final badKey = _builder({'APP_KEY': 'not-base64'}).create();
    await expectLater(badKey.boot(), throwsA(isA<ConfigException>()));

    final shortKey = _builder({'APP_KEY': 'base64:AAAA'}).create();
    await expectLater(shortKey.boot(), throwsA(isA<ConfigException>()));

    final badDb = _builder({'DB_CONNECTION': 'oracle'}).create();
    await expectLater(badDb.boot(), throwsA(isA<ConfigException>()));

    final good = _builder({'APP_KEY': 'base64:${'A' * 43}='}).create();
    await good.boot();
    await good.shutdown();
  });

  test('withConfig registers a section under its own type', () async {
    final app = _builder({'BILLING_CURRENCY': 'EUR'})
        .withConfig(_BillingConfig.fromEnv)
        .create();
    await app.boot();
    // section<T>() found nothing before: it was stored as ConfigSection.
    expect(app.config.section<_BillingConfig>().currency, 'EUR');
    expect(app.config.get<String>('billing.currency'), 'EUR');
    await app.shutdown();
  });

  test('custom config checks participate in validation', () async {
    final app = _builder({})
        .withConfigCheck(
          (env, config) => [
            if (!env.has('PAYMENT_KEY'))
              const ConfigIssue(ConfigIssueLevel.error, 'PAYMENT_KEY missing'),
          ],
        )
        .create();
    await expectLater(
      app.boot(),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('PAYMENT_KEY'),
        ),
      ),
    );
  });

  test(
    'serving an in-memory SQLite database on several isolates is refused',
    () async {
      final app = _builder({}).create();
      await app.boot();
      await expectLater(
        app.serve(options: const ServeOptions(isolates: 4, port: 0)),
        throwsA(isA<ConfigException>()),
      );
      await app.shutdown();
    },
  );
}

final class _BillingConfig implements ConfigSection {
  const _BillingConfig(this.currency);

  factory _BillingConfig.fromEnv(Env env) =>
      _BillingConfig(env.string('BILLING_CURRENCY', 'IDR'));

  final String currency;

  @override
  String get key => 'billing';

  @override
  Map<String, Object?> toMap() => {'currency': currency};
}
