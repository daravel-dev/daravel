import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Report extends Job {
  const Report();
  @override
  String get jobName => 'report';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

final class Pinned extends Job {
  const Pinned();
  @override
  String get jobName => 'pinned';
  @override
  String? get queue => 'own';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

void main() {
  late Directory base;
  late Application app;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_queue_route');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<T> faked<T>(Future<T> Function(QueueFake fake) body) =>
      app.run(() => body(Queue.manager.fake()));

  test(
    'a route sends a job where it says',
    () => faked((fake) async {
      Queue.route<Report>(queue: 'reports', connection: 'sync');
      await Queue.dispatch(const Report());
      expect(fake.pushed.single.queue, 'reports');
      expect(fake.pushed.single.connection, 'sync');
    }),
  );

  test(
    'the dispatch and the job win over a route',
    () => faked((fake) async {
      Queue.route<Report>(queue: 'reports');
      Queue.route<Pinned>(queue: 'reports');
      await Queue.dispatch(const Report()).onQueue('now');
      await Queue.dispatch(const Pinned());
      expect(fake.pushed.first.queue, 'now');
      expect(fake.pushed.last.queue, 'own');
    }),
  );

  test(
    'other jobs are left alone',
    () => faked((fake) async {
      Queue.route<Pinned>(connection: 'sync');
      await Queue.dispatch(const Report());
      expect(fake.pushed.single.queue, isNot('reports'));
    }),
  );

  test(
    'withoutDelay clears the delay',
    () => faked((fake) async {
      await Queue.dispatch(const Report())
          .delay(const Duration(minutes: 5))
          .withoutDelay();
      expect(fake.pushed.single.delay, Duration.zero);
    }),
  );
}
