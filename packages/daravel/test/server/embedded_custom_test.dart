// H2 (Blueprint #134): custom embedded workers and coordinator services.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Counts calls and remembers the workers that exited.
final class TallyService implements CoordinatorService, WorkerAwareService {
  final Map<String, int> counts = {};
  final List<String> forgotten = [];

  @override
  String get name => 'tally';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    switch (op) {
      case 'hit':
        final key = args['key']! as String;
        return counts[key] = (counts[key] ?? 0) + 1;
      case 'get':
        return counts[args['key']! as String] ?? 0;
    }
    throw CoordinatorException('Unknown tally operation [$op].');
  }

  @override
  void forgetWorker(String worker) => forgotten.add(worker);

  @override
  Map<String, Object?> stats() => {'keys': counts.length};
}

Future<int> _hit(Application app, String key) async =>
    (await app.container.make<CoordinatorChannel>().call('tally', 'hit', {
          'key': key,
        }))!
        as int;

/// The custom worker: counts its start, crashes on its first start, then
/// counts every message and returns on `stop`.
Future<int> _ticker(Application app, EmbeddedControl control) async {
  if (await _hit(app, 'started') == 1) {
    throw StateError('first start crashes on purpose');
  }
  await for (final message in control.messages) {
    if (message == 'stop') {
      break;
    }
    await _hit(app, 'message:$message');
  }
  await control.stopping;
  return 0;
}

ApplicationBuilder _base() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withEmbeddedWorker('ticker', _ticker)
        .withCoordinatorService(TallyService.new)
        .withRouting(
          api: (r) => r.get('/hit', (request) async {
            final channel = App.make<CoordinatorChannel>();
            final count = await channel.call('tally', 'hit', {'key': 'http'});
            return Response.json({'count': count});
          }),
        );

/// Top-level, so it can be sent to isolates.
Application tickerApp() => _base().create();

Future<void> until(Future<bool> Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test('withCoordinatorService registers on the application\'s own '
      'coordinator (one isolate)', () async {
    final app = tickerApp();
    await app.boot();
    addTearDown(app.shutdown);
    final channel = app.container.make<CoordinatorChannel>();
    expect(channel, isA<LocalCoordinatorChannel>());
    expect(await channel.call('tally', 'hit', {'key': 'a'}), 1);
    expect(await channel.call('tally', 'hit', {'key': 'a'}), 2);
    final coordinator = (channel as LocalCoordinatorChannel).coordinator;
    expect((coordinator.stats()['services'] as Map)['tally'], {'keys': 1});
    expect(app.embeddedWorkerNames, ['ticker']);
  });

  test('withEmbeddedWorker refuses the built-in names and odd ones', () {
    Future<int> entry(Application app, EmbeddedControl control) async => 0;
    for (final name in ['queue', 'scheduler', 'Horizon', '', 'a b']) {
      expect(
        () =>
            Application.configure(basePath: '.')
                .withEmbeddedWorker(name, entry),
        throwsArgumentError,
        reason: name,
      );
    }
  });

  test('serve refuses an embedded worker nothing registered', () async {
    await expectLater(
      Application.serveWith(
        tickerApp,
        port: await freePort(),
        embedWorkers: ['horizon'],
      ),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('[horizon]'), contains('registered: ticker')),
        ),
      ),
    );
  });

  test('ServeOptions reads SERVER_EMBED_WORKERS', () {
    final options = ServeOptions.fromEnv(
      Env.fromMap({'SERVER_EMBED_WORKERS': 'horizon, ticker,'}),
    );
    expect(options.embedWorkers, ['horizon', 'ticker']);
    expect(ServeOptions.fromEnv(Env.fromMap({})).embedWorkers, isEmpty);
    expect(
      ServeOptions.fromEnv(Env.fromMap({}), embedWorkers: ['x']).embedWorkers,
      ['x'],
    );
  });

  test(
    'a custom embedded worker gets the coordinator and messages, is started '
    'again after a crash, and stops when asked',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final tally = TallyService();
      final coordinator = createStandardCoordinator()..register(tally);
      addTearDown(coordinator.close);
      final embedded = EmbeddedWorkers(
        tickerApp,
        roles: const [],
        custom: const ['ticker'],
        logger: Logger(minimumLevel: LogLevel.critical),
        coordinator: coordinator.listen(),
        crashDelay: (_) => const Duration(milliseconds: 50),
      );
      await embedded.start();
      // The first start crashed; the second one runs.
      await until(
        () async => (tally.counts['started'] ?? 0) >= 2,
        'the respawn after the crash',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await embedded.send('ticker', 'ping');
      await embedded.send('queue', 'ignored: not a custom worker');
      await until(() async => tally.counts['message:ping'] == 1, 'the message');
      await embedded.stop(timeout: const Duration(seconds: 10));
      expect(tally.counts['started'], 2, reason: 'no respawn after stop');
    },
  );

  test(
    'a coordinator service answers worker isolates through the supervisor, '
    'and hears when they exit',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final tally = TallyService();
      final coordinator = createStandardCoordinator()..register(tally);
      final port = await freePort();
      final supervisor = Supervisor(
        tickerApp,
        ServeOptions(
          host: '127.0.0.1',
          port: port,
          isolates: 2,
          handleSignals: false,
          shutdownTimeout: const Duration(seconds: 10),
          readyTimeout: const Duration(seconds: 60),
        ),
        logger: Logger(minimumLevel: LogLevel.critical),
        coordinator: coordinator,
      );
      await supervisor.start();
      final client = HttpClient();
      try {
        for (var i = 1; i <= 4; i++) {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$port/api/hit'),
          );
          final response = await request.close();
          final body = jsonDecode(
            await response.transform(utf8.decoder).join(),
          ) as Map<String, Object?>;
          expect(body['count'], i);
        }
      } finally {
        client.close();
        await supervisor.stop();
      }
      expect(tally.counts['http'], 4);
      expect(tally.forgotten.toSet(), {'daravel-worker-0', 'daravel-worker-1'});
    },
  );
}
