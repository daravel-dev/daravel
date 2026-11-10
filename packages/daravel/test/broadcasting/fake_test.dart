import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class OrderShipped with ShouldBroadcast {
  OrderShipped(this.id);
  final int id;
  @override
  List<String> broadcastOn() => [Channels.private('orders.$id')];
  @override
  Map<String, Object?> broadcastWith() => {'id': id};
}

final class OrderCancelled with ShouldBroadcast {
  @override
  List<String> broadcastOn() => ['orders'];
}

void main() {
  late Application app;

  setUp(() async {
    app =
        Application.configure(
          basePath: Directory.systemTemp.createTempSync('daravel_fake_').path,
        ).withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          // Would throw without a server: the fake never sends.
          'BROADCAST_CONNECTION': 'daravel',
        }).create();
    await app.boot();
  });

  tearDown(() => app.shutdown());

  test('records events and sends instead of broadcasting them', () async {
    await app.run(() async {
      final fake = Broadcast.fake();
      await Broadcast.event(OrderShipped(7));
      await Broadcast.send('price.updated', ['prices'], {'sku': 'A1'});
      expect(fake.broadcasts, hasLength(2));
      expect(fake.broadcasts.first.source, isA<OrderShipped>());
      expect(fake.broadcasts.first.data, {'id': 7});

      fake
        ..assertBroadcasted<OrderShipped>()
        ..assertBroadcasted<OrderShipped>(channel: 'private-orders.7')
        ..assertBroadcasted<OrderShipped>(where: (e) => e.id == 7)
        ..assertBroadcastedTimes<OrderShipped>(1)
        ..assertSent('price.updated', channel: 'prices')
        ..assertNotBroadcasted<OrderCancelled>()
        ..assertNothingBroadcastedTo('orders');
      expect(
        () => fake.assertBroadcasted<OrderShipped>(channel: 'private-orders.8'),
        throwsStateError,
      );
      expect(() => fake.assertBroadcasted<OrderCancelled>(), throwsStateError);
      expect(
        () => fake.assertBroadcastedTimes<OrderShipped>(2),
        throwsStateError,
      );
      expect(() => fake.assertNothingBroadcastedTo('prices'), throwsStateError);
      expect(fake.assertNothingBroadcasted, throwsStateError);
    });
  });

  test(
    'a broadcast in a transaction that rolls back is not recorded',
    () async {
      await app.run(() async {
        final fake = Broadcast.fake();
        try {
          await DB.transaction(() async {
            await Broadcast.event(OrderShipped(1));
            throw StateError('rolled back');
          });
        } on StateError {
          // Rolled back.
        }
        fake.assertNothingBroadcasted();
        await DB.transaction(() => Broadcast.event(OrderShipped(2)));
        fake.assertBroadcasted<OrderShipped>(where: (e) => e.id == 2);
      });
    },
  );

  test('restore() sends again', () async {
    await app.run(() async {
      Broadcast.fake();
      Broadcast.restore();
      expect(Broadcast.manager.faked, isNull);
      // Without a server, BROADCAST_CONNECTION=daravel refuses to send.
      await expectLater(Broadcast.event(OrderShipped(3)), throwsStateError);
    });
  });
}
