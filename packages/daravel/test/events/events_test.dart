import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class OrderPlaced {
  const OrderPlaced(this.id);
  final int id;
}

final class BigOrderPlaced extends OrderPlaced {
  const BigOrderPlaced(super.id);
}

final class AuditSubscriber implements EventSubscriber {
  AuditSubscriber(this.log);
  final List<String> log;

  @override
  void subscribe(EventDispatcher events) {
    events.listen<OrderPlaced>((e) => log.add('audit:${e.id}'), priority: -10);
  }
}

final class NotifyWarehouse extends QueuedListener<OrderPlaced> {
  const NotifyWarehouse(this.log);
  final List<String> log;

  @override
  Future<void> handle(OrderPlaced event) async =>
      log.add('warehouse:${event.id}');

  @override
  Map<String, Object?> eventToJson(OrderPlaced event) => {'id': event.id};

  @override
  OrderPlaced eventFromJson(Map<String, Object?> json) =>
      OrderPlaced(json['id']! as int);
}

void main() {
  test(
    'listeners run by priority, once listeners drop out, subtypes match',
    () async {
      final events = EventDispatcher();
      final log = <String>[];
      events
        ..listen<OrderPlaced>((e) => log.add('low:${e.id}'), priority: 0)
        ..listen<OrderPlaced>(
          (e) async => log.add('high:${e.id}'),
          priority: 10,
        )
        ..listen<OrderPlaced>((e) => log.add('once:${e.id}'), once: true)
        ..subscribe(AuditSubscriber(log));
      expect(events.hasListeners<OrderPlaced>(), isTrue);
      expect(events.hasListeners<String>(), isFalse);
      await events.dispatch(const OrderPlaced(1));
      await events.dispatch(const BigOrderPlaced(2));
      expect(log, [
        'high:1',
        'low:1',
        'once:1',
        'audit:1',
        'high:2',
        'low:2',
        'audit:2',
      ]);
      events.forget<OrderPlaced>();
      expect(events.hasListeners<OrderPlaced>(), isFalse);
    },
  );

  test('streams and fakes', () async {
    final events = EventDispatcher();
    final seen = <int>[];
    final subscription = events.on<OrderPlaced>().listen((e) => seen.add(e.id));
    await events.dispatch(const OrderPlaced(5));
    await Future<void>.delayed(Duration.zero);
    expect(seen, [5]);
    await subscription.cancel();

    final fake = events.fake();
    await events.dispatch(const OrderPlaced(6));
    await events.dispatch(const BigOrderPlaced(7));
    expect(fake.dispatchedTimes<OrderPlaced>(), 2);
    expect(fake.of<BigOrderPlaced>().single.id, 7);
    fake.assertDispatched<OrderPlaced>((e) => e.id == 6);
    expect(() => fake.assertNotDispatched<OrderPlaced>(), throwsStateError);
    expect(() => fake.assertDispatched<String>(), throwsStateError);
    expect(seen, [5]);
    events.restore();
    await events.dispatch(const OrderPlaced(8));
    expect(seen, [5]); // stream unsubscribed
  });

  test('queued listeners push a job that replays the event', () async {
    final events = EventDispatcher();
    final log = <String>[];
    final pushed = <Job>[];
    final definition = events.listenQueued<OrderPlaced>(NotifyWarehouse(log));
    events.queuePusher = (job) async {
      pushed.add(job);
      return 1;
    };
    await events.dispatch(const OrderPlaced(9));
    expect(log, isEmpty);
    expect(pushed.single, isA<CallQueuedListener>());
    final job = pushed.single as CallQueuedListener;
    expect(job.jobName, 'daravel:listener:NotifyWarehouse');
    expect(job.toJson(), {
      'event': {'id': 9},
    });

    // A worker rebuilds the job through the registry and runs the listener.
    final registry = JobRegistry([definition]);
    final rebuilt = registry.make(job.jobName, job.toJson());
    await rebuilt.handle(
      JobContext(
        id: 1,
        attempt: 1,
        queue: 'default',
        connection: 'sync',
        payload: const {},
      ),
    );
    expect(log, ['warehouse:9']);
    expect(
      () => events.listenQueued<OrderPlaced>(NotifyWarehouse(log)),
      throwsA(isA<ConfigException>()),
    );
  });

  test(
    'dispatchAfterCommit waits for the transaction and drops on rollback',
    () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withEvents(
            (events) => events.listen<OrderPlaced>((e) => _log.add(e.id)),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      _log.clear();
      await app.run(() async {
        await DB.transaction(() async {
          await Event.dispatchAfterCommit(const OrderPlaced(1));
          await DB.transaction(() async {
            await Event.dispatchAfterCommit(const OrderPlaced(2));
          });
          expect(_log, isEmpty);
        });
        expect(_log, [1, 2]);

        await expectLater(
          DB.transaction(() async {
            await Event.dispatchAfterCommit(const OrderPlaced(3));
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(_log, [1, 2]);

        // Nested rollback keeps the outer transaction's callbacks only.
        await DB.transaction(() async {
          await Event.dispatchAfterCommit(const OrderPlaced(4));
          try {
            await DB.transaction(() async {
              await Event.dispatchAfterCommit(const OrderPlaced(5));
              throw StateError('inner');
            });
          } on StateError {
            // expected
          }
        });
        expect(_log, [1, 2, 4]);

        // No transaction → immediate.
        await Event.dispatchAfterCommit(const OrderPlaced(6));
        expect(_log, [1, 2, 4, 6]);
      });
    },
  );
}

final List<int> _log = <int>[];
