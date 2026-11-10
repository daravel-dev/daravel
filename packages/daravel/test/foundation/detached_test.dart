import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Work that outlives the request, job or command starting it runs outside
/// that scope (Review #149).
void main() {
  late Application app;
  late MemoryHandler logs;
  var closed = false;
  final uncaught = <Object>[];

  setUp(() async {
    uncaught.clear();
    closed = false;
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.debug)
        .create();
    await app.boot();
    logs = await app.run(() async => Log.spy());
  });
  tearDown(() async {
    if (!closed) {
      await app.shutdown();
    }
  });

  /// [body] as a request runs: a scope of its own, a request id in its log
  /// context, and its own handler of stray errors.
  Future<T> inRequest<T>(FutureOr<T> Function() body) =>
      app.container.runScoped('request', (_) async {
        Log.withContext({'request_id': 'r-1'});
        return body();
      }, onUncaughtError: (error, _) => uncaught.add(error));

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  test('a timer started in a request runs with no scope and logs with no '
      'request id, after the request ended', () async {
    var ran = false;
    Scope? scopeSeen;
    late Detached<Timer> task;
    await inRequest(() {
      task = runDetached(
        () => Timer(const Duration(milliseconds: 50), () {
          ran = true;
          scopeSeen = Container.current.currentScope;
          Log.info('from the timer');
        }),
        name: 'test timer',
      );
    });
    await until(
      () => logs.matching(LogLevel.info, 'from the timer').isNotEmpty,
    );
    expect(ran, isTrue);
    expect(scopeSeen, isNull, reason: 'no request scope');
    final record = logs.matching(LogLevel.info, 'from the timer').single;
    expect(record.context.containsKey('request_id'), isFalse);
    expect(task.name, 'test timer');
  });

  test('an error it leaves uncaught is logged with its name, never handed '
      'to the request', () async {
    await inRequest(() {
      runDetached(
        () => Timer(Duration.zero, () => throw StateError('in the timer')),
        name: 'failing timer',
      );
    });
    await until(
      () => logs
          .matching(LogLevel.error, 'Detached task failing timer')
          .isNotEmpty,
    );
    expect(uncaught, isEmpty);
  });

  test('a job\'s cancellation token does not reach it: its transaction '
      'still commits after the token is cancelled', () async {
    await app.run(() => DB.statement('CREATE TABLE ticks (n INTEGER)'));
    final token = CancellationToken();
    late Completer<Object?> done;
    done = Completer<Object?>();
    token.run(() {
      runDetached(
        () => Timer(const Duration(milliseconds: 50), () {
          DB
              .transaction(() => DB.table('ticks').insert({'n': 1}))
              .then(done.complete, onError: done.complete);
        }),
        name: 'loop of a job',
      );
    });
    token.cancel('the job timed out');
    final outcome = await done.future.timeout(const Duration(seconds: 5));
    expect(outcome, isNot(isA<OperationCancelledException>()));
    expect(await app.run(() => DB.table('ticks').count()), 1);
  });

  test('a database connection opened inside a request logs without the '
      'request id, and names its driver', () async {
    await inRequest(() => DB.connection());
    final opened = logs.matching(LogLevel.debug, 'Database connection').first;
    expect(opened.message, 'Database connection [sqlite] (sqlite) opened.');
    expect(opened.context.containsKey('request_id'), isFalse);
  });

  test('runDetachedAsync hands its error to the caller, in the caller\'s '
      'zone', () async {
    final caught = await inRequest(() async {
      try {
        await runDetachedAsync<void>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw StateError('start failed');
        }, name: 'failing start').value;
        return 'no error';
      } on StateError catch (error) {
        return error.message;
      }
    }).timeout(const Duration(seconds: 5));
    expect(caught, 'start failed');
    expect(uncaught, isEmpty);
  });

  test('the rate limit lease reaper a request starts gives leases back from '
      'no scope (not the request\'s)', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final channel = _ScopeRecorder(coordinator);
    final store = ProcessRateLimitStore(
      channel,
      leaseTtl: const Duration(milliseconds: 50),
    );
    await inRequest(() async {
      // The first lease (one hit) is used up; the second holds two, one of
      // which the reaper gives back once it expires.
      for (var i = 0; i < 2; i++) {
        await store.attempt('k', 100, const Duration(minutes: 1));
      }
    });
    await until(() => channel.releases.isNotEmpty);
    expect(channel.releases.first, isNull);
  });

  test('the application stops its detached tasks when it shuts down', () async {
    var ticks = 0;
    final task = await app.run(
      () async => runDetached(
        () => Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++),
        name: 'ticker',
      ),
    );
    expect(app.container.make<DetachedTasks>().names, contains('ticker'));
    await until(() => ticks > 0);
    closed = true;
    await app.shutdown();
    expect(task.cancelled, isTrue);
    expect(task.value.isActive, isFalse);
    final after = ticks;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ticks, after);
  });
}

/// A coordinator channel that records the scope each `release` (a lease
/// given back by the reaper) is sent from.
final class _ScopeRecorder implements CoordinatorChannel {
  _ScopeRecorder(this.coordinator);

  final Coordinator coordinator;
  final List<Scope?> releases = [];

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
    if (op == 'release') {
      releases.add(Container.currentOrNull?.currentScope);
    }
    return coordinator.handle(service, op, args);
  }
}
