import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Noop extends Job {
  const Noop();
  factory Noop.fromJson(Map<String, Object?> json) => const Noop();
  @override
  String get jobName => 'noop';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

Application waitApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'memory',
        })
        .withLogLevel(LogLevel.critical)
        .withJobs([JobDefinition('noop', Noop.fromJson)])
        .withHorizon(
          createApp: waitApp,
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('default')],
            ),
          ],
          waits: const {'memory:default': Duration(seconds: 60)},
        )
        .create();

void main() {
  tearDown(travelBack);

  test('LongWaitDetected: a queue past its wait threshold, dispatched to the '
      "application's listeners, once per queue every 5 minutes", () async {
    final app = waitApp();
    await app.boot();
    addTearDown(app.shutdown);
    final heard = <LongWaitDetected>[];
    app.container.make<EventDispatcher>().listen<LongWaitDetected>(heard.add);
    freezeTime();
    await app.run(() => Queue.push(const Noop()));
    final queues = app.container.make<QueueManager>();
    final config = app.config.section<HorizonConfig>();
    final master = HorizonMaster(
      waitApp,
      config,
      driver: queues.connection,
      logger: app.logger,
      onEvent: horizonEvents(app),
    );

    // What balance() reads from the queue, without running workers.
    Future<void> evaluate() async {
      final queue = queues.connection(null);
      master.detectLongWaits(queue.name, [
        QueueLoad(
          queue: const QueueName('default'),
          size: await queue.size('default'),
          oldestWait: await queue.oldestWait('default'),
          targetWait: config.waitFor(queue.name, 'default'),
        ),
      ]);
      await pumpEventQueue();
    }

    // Under the threshold: nothing.
    travel(const Duration(seconds: 30));
    await evaluate();
    expect(heard, isEmpty);

    travel(const Duration(minutes: 2));
    await evaluate();
    await evaluate();
    final event = heard.single;
    expect(event.connection, 'memory');
    expect(event.queue, 'default');
    expect(event.wait, greaterThanOrEqualTo(const Duration(minutes: 2)));
    expect(event.threshold, const Duration(seconds: 60));
  });
}
