@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Server-sent events kept in a stream, on one server
/// (`DARAVEL_TEST_REDIS`) and a cluster (`DARAVEL_TEST_REDIS_CLUSTER`).
void main() {
  for (final (name, variable) in [
    ('server', 'DARAVEL_TEST_REDIS'),
    ('cluster', 'DARAVEL_TEST_REDIS_CLUSTER'),
  ]) {
    final url = Platform.environment[variable];
    if (url == null || url.isEmpty) {
      test('events on a $name (skipped: $variable not set)', () {}, skip: true);
      continue;
    }
    group('events on a $name', () {
      late String prefix;
      late RedisClient client;
      late RedisEventStream orders;

      setUp(() {
        prefix = 'test_${Random().nextInt(1 << 32)}_';
        client = RedisClient(RedisConnectionConfig.fromUrl(url));
        orders = RedisEventStream(client, '${prefix}sse:orders');
      });
      tearDown(() async {
        await client.del(['${prefix}sse:orders']);
        await client.close();
      });

      test('a client coming back gets what it missed, then live', () async {
        final first = await orders.publish({'id': 1}, event: 'created');
        await orders.publish({'id': 2}, event: 'created');
        await orders.publish('three');
        final events = StreamIterator(orders.listen(lastEventId: first));
        expect(await events.moveNext(), isTrue);
        expect(events.current.data, {'id': 2});
        expect(events.current.event, 'created');
        expect(await events.moveNext(), isTrue);
        expect(events.current.data, 'three');
        expect(events.current.event, 'update');
        final fourth = await orders.publish({'id': 4});
        expect(await events.moveNext(), isTrue);
        expect(events.current.id, fourth);
        expect(events.current.encode(), contains('id: $fourth\n'));
        await events.cancel();
      });

      test('without Last-Event-ID, only live events', () async {
        await orders.publish('old');
        final events = StreamIterator(orders.listen());
        final next = events.moveNext();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await orders.publish('new');
        expect(await next, isTrue);
        expect(events.current.data, 'new');
        await events.cancel();
      });

      test('a catch-up racing live events loses and repeats none', () async {
        final start = await orders.publish(0);
        final received = <Object?>[];
        final done = Completer<void>();
        final publishing = () async {
          for (var i = 1; i <= 50; i++) {
            await orders.publish(i);
          }
        }();
        final subscription = orders.listen(lastEventId: start).listen((e) {
          received.add(e.data);
          if (e.data == 50) {
            done.complete();
          }
        });
        await publishing;
        await done.future.timeout(const Duration(seconds: 10));
        await subscription.cancel();
        expect(received, [for (var i = 1; i <= 50; i++) i]);
      });

      if (name == 'server') {
        test('listeners share one connection, closed with the last', () async {
          final a = orders.listen().listen((_) {});
          final b = orders.listen().listen((_) {});
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(client.stats['dedicated'], 1);
          await a.cancel();
          await b.cancel();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(client.stats['dedicated'], 0);
        });

        test('Response.sse resumes from the request header', () async {
          final first = await orders.publish('a');
          await orders.publish('b');
          final request = Request.fake(headers: {'last-event-id': first});
          final events = orders.since(request);
          expect((await events.first).data, 'b');
        });
      }
    });
  }
}
