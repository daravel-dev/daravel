import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The places that share one computation between callers of different
/// zones (PR B of the SharedResult work): when the computation fails,
/// every caller gets the error, in its own zone, and none hangs.
void main() {
  late Container container;
  final uncaught = <Object>[];

  setUp(() {
    container = Container();
    uncaught.clear();
  });

  /// [body] in a request scope of its own, as a request runs.
  Future<R> inRequest<R>(Future<R> Function() body) => container.runScoped(
    'request',
    (_) => body(),
    onUncaughtError: (error, _) => uncaught.add(error),
  );

  /// Two callers, each in its own request, joining one computation: what
  /// each got, within a few seconds (a hang fails the test).
  Future<List<String>> both(Future<Object?> Function() call) => Future.wait([
    for (var i = 0; i < 2; i++)
      inRequest(() async {
        try {
          await call();
          return 'value';
        } on Object catch (error) {
          return error.runtimeType.toString();
        }
      }),
  ]).timeout(const Duration(seconds: 5));

  test(
    'remember: a failing loader reaches every request missing the key',
    () async {
      final cache = CacheRepository(MemoryStore());
      final answers = await both(
        () => cache.remember<String>('k', null, () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          throw StateError('loader failed');
        }),
      );
      expect(answers, ['StateError', 'StateError']);
      expect(uncaught, isEmpty);
    },
  );

  test('a connection that fails to open reaches every request asking for '
      'it', () async {
    final db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'main',
        connections: {
          'main': ConnectionConfig(driver: 'failing', database: 'x'),
        },
      ),
      drivers: {'failing': (name, _) => _FailingDriver(name)},
    );
    final answers = await both(db.connection);
    expect(answers, ['StateError', 'StateError']);
    expect(uncaught, isEmpty);
  });

  test('the dummy hash of logins with no user: a saturated pool reaches '
      'every login waiting on it, as the same error', () async {
    final hash = HashManager(
      const HashConfig(
        concurrency: 1,
        maxQueue: 8,
        queueTimeout: Duration(milliseconds: 100),
        bcryptRounds: 14,
      ),
    );
    addTearDown(hash.close);
    // The one hashing isolate busy for a while.
    unawaited(hash.make('keeps the pool busy').then((_) {}, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final answers = await both(() => hash.checkAgainstDummy('guess'));
    expect(answers, ['HashingSaturatedException', 'HashingSaturatedException']);
    expect(uncaught, isEmpty);
  });

  test('a channel registration that fails reaches every subscriber of the '
      'channel', () async {
    final broadcaster = Broadcaster(_FailingSubscribe());
    addTearDown(broadcaster.close);
    final answers = await both(() => broadcaster.subscribe('news'));
    expect(answers, [
      'CoordinatorTimeoutException',
      'CoordinatorTimeoutException',
    ]);
    expect(uncaught, isEmpty);
  });
}

/// A driver whose connection fails after a moment.
final class _FailingDriver implements DatabaseDriver {
  _FailingDriver(this.name);

  @override
  final String name;

  @override
  Future<void> connect() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    throw StateError('cannot connect');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A coordinator whose broadcast subscribe times out after a moment.
final class _FailingSubscribe implements CoordinatorChannel {
  @override
  StateScope get scope => StateScope.process;

  @override
  bool get isRemote => true;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    throw CoordinatorTimeoutException(service, timeout);
  }
}
