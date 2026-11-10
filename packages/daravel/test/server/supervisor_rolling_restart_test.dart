import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Set per isolate when its application is built: a new value after each
/// restart.
final String bootId = '${Random().nextInt(1 << 32)}';

/// When this file exists, a worker's application fails to build (a
/// replacement that never comes up).
final String failMarker =
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'daravel_rolling_fail_$pid';

Application rollingApp() {
  if (File(failMarker).existsSync()) {
    throw StateError('broken release');
  }
  return Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .withRouting(
        apiPrefix: '',
        api: (router) => router.get(
          '/boot',
          (_) => {
            'boot': bootId,
            'supervised': App.make<Application>().supervised,
          },
        ),
      )
      .create();
}

/// What the hooks and the main isolate's application did, in order (the
/// hooks run in this isolate; the workers' copies of it are their own).
final List<String> trace = [];

/// The supervisor the hooks saw.
Supervisor? hooked;
int hookCalls = 0;

/// A file database: serveWith refuses an in-memory one with several
/// isolates (each would get its own).
final String hookDb =
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'daravel_rolling_hooks_$pid.sqlite';

ApplicationBuilder hookBase() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': hookDb})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) => router
            ..get('/boot', (_) => {'boot': bootId})
            ..get('/restart', (_) async {
              await App.make<Application>().restart();
              return 'restarting';
            }),
        )
        .withShutdown((_) async => trace.add('closed'));

/// A hook that keeps something running (it returns a stop function, which
/// throws), one that fails later in what it started, and one that throws
/// while it is installed.
Application hookedApp() => hookBase()
    .withSupervisorHook((app, supervisor) {
      hookCalls++;
      hooked = supervisor;
      Timer(const Duration(milliseconds: 10), () => throw StateError('late'));
      return () {
        trace.add('stop');
        throw StateError('stop fails too');
      };
    })
    .withSupervisorHook((app, supervisor) => throw StateError('at install'))
    .create();

/// Only a hook that keeps nothing (null).
Application nullHookApp() => hookBase().withSupervisorHook((app, supervisor) {
  hookCalls++;
  hooked = supervisor;
  return null;
}).create();

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late int port;
  late HttpClient client;

  setUp(() async {
    port = await freePort();
    client = HttpClient();
    addTearDown(() => client.close(force: true));
  });

  /// GET /boot; [fresh] on a new connection (a new client), not one kept
  /// alive from before.
  Future<Map<String, Object?>> boot({bool fresh = false}) async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/boot'),
    );
    request.persistentConnection = !fresh;
    final response = await request.close();
    return (jsonDecode(await utf8.decodeStream(response)) as Map)
        .cast<String, Object?>();
  }

  Future<Supervisor> supervised(int isolates) async {
    final supervisor = Supervisor(
      rollingApp,
      ServeOptions(
        host: '127.0.0.1',
        port: port,
        isolates: isolates,
        handleSignals: false,
        shutdownTimeout: const Duration(seconds: 5),
        readyTimeout: const Duration(seconds: 60),
      ),
      logger: Logger(minimumLevel: .critical),
    );
    await supervisor.start();
    addTearDown(supervisor.stop);
    return supervisor;
  }

  test(
    'workers restart one at a time: every request on the way is answered',
    () async {
      final supervisor = await supervised(3);
      final before = <Object?>{};
      for (var i = 0; i < 30; i++) {
        before.add((await boot())['boot']);
      }
      expect((await boot())['supervised'], isTrue);

      final failures = <String>[];
      var answered = 0;
      var rolling = true;
      final load = () async {
        while (rolling) {
          try {
            await boot(fresh: true);
            answered++;
          } on Object catch (error) {
            failures.add('$error');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }();
      final result = await supervisor.rollingRestart();
      rolling = false;
      await load;

      expect(result.completed, isTrue, reason: result.summary);
      expect(result.workers.map((w) => w.status), [
        for (var i = 0; i < 3; i++) WorkerRestartStatus.restarted,
      ]);
      expect(failures, isEmpty, reason: 'answered $answered');
      final after = <Object?>{};
      for (var i = 0; i < 30; i++) {
        after.add((await boot())['boot']);
      }
      expect(after.intersection(before), isEmpty, reason: 'all new workers');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a replacement that fails stops the round; the others keep serving',
    () async {
      final supervisor = await supervised(3);
      File(failMarker).writeAsStringSync('');
      addTearDown(() {
        if (File(failMarker).existsSync()) {
          File(failMarker).deleteSync();
        }
      });
      final result = await supervisor.rollingRestart(
        readyTimeout: const Duration(seconds: 10),
      );
      expect(result.completed, isFalse);
      expect(result.workers.map((w) => w.status), [
        WorkerRestartStatus.failed,
        WorkerRestartStatus.skipped,
        WorkerRestartStatus.skipped,
      ]);
      // The two left serve on.
      for (var i = 0; i < 10; i++) {
        expect((await boot())['boot'], isNotNull);
      }
      File(failMarker).deleteSync();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('calls during a round make one more round, not one each', () async {
    final supervisor = await supervised(2);
    final rounds = <RollingRestart>[];
    supervisor.onRollingRestart = rounds.add;
    final first = supervisor.rollingRestart();
    final second = supervisor.rollingRestart();
    final third = supervisor.rollingRestart();
    await Future.wait([first, second, third]);
    expect(rounds, hasLength(2));
    expect(identical(await second, await third), isTrue);
    expect(rounds.every((r) => r.completed), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('while stopping every worker is skipped', () async {
    final supervisor = await supervised(2);
    final stopping = supervisor.stop();
    final result = await supervisor.rollingRestart();
    await stopping;
    expect(result.completed, isFalse);
    expect(result.workers.map((w) => w.status), [
      WorkerRestartStatus.skipped,
      WorkerRestartStatus.skipped,
    ]);
  }, timeout: const Timeout(Duration(minutes: 1)));

  Future<void> waitFor(bool Function() done, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void resetHooks() {
    hooked = null;
    hookCalls = 0;
    trace.clear();
  }

  test(
    'hooks run in the main isolate; their errors are logged, the server '
    'serves on, and the application they keep closes after their stop',
    () async {
      resetHooks();
      final served = Application.serveWith(
        hookedApp,
        host: '127.0.0.1',
        port: port,
        isolates: 2,
      );
      await waitFor(() => hooked != null, 'the hooks');
      expect(hookCalls, 1);
      expect(Isolate.current.debugName, isNot(startsWith('daravel-worker')));
      // After the timer that throws.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await boot())['boot'], isNotNull);
      expect(trace, isEmpty, reason: 'kept while a hook runs something');
      await hooked!.stop();
      expect(await served, 0);
      expect(trace, ['stop', 'closed']);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('when every hook returns null the main isolate application is closed '
      'at once', () async {
    resetHooks();
    final served = Application.serveWith(
      nullHookApp,
      host: '127.0.0.1',
      port: port,
      isolates: 2,
    );
    await waitFor(() => trace.contains('closed'), 'the application closed');
    expect(hookCalls, 1);
    expect((await boot())['boot'], isNotNull, reason: 'workers serve on');
    await hooked!.stop();
    expect(await served, 0);
    expect(trace, ['closed']);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('with one isolate no hook runs', () async {
    resetHooks();
    final served = Application.serveWith(
      hookedApp,
      host: '127.0.0.1',
      port: port,
      isolates: 1,
    );
    var up = false;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!up && DateTime.now().isBefore(deadline)) {
      try {
        await boot();
        up = true;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(up, isTrue);
    // Application.restart: a server of one isolate ends.
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/restart'),
    );
    await (await request.close()).drain<void>();
    expect(await served.timeout(const Duration(seconds: 30)), 0);
    expect(hookCalls, 0);
    expect(hooked, isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
