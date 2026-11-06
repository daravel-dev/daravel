import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Coordinator coordinator;
  late ReceivePort survivor;
  late StreamIterator<Object?> frames;

  setUp(() {
    coordinator = createStandardCoordinator();
    survivor = ReceivePort();
    frames = StreamIterator(survivor);
  });

  tearDown(() async {
    await frames.cancel();
    survivor.close();
  });

  Future<Object?> call(String service, String op, Map<String, Object?> args) =>
      coordinator.handle(service, op, args);

  Future<void> join(String socket, String user, String worker) =>
      call('channels', 'join', {
        'channel': 'presence-room',
        'socket': socket,
        'user_id': user,
        'user_info': {'name': user},
        'worker': worker,
      });

  /// The `(event, user_id)` of the next frame the surviving worker gets, or
  /// null when none comes within a second.
  Future<(String, String)?> nextFrame() async {
    if (!await frames.moveNext().timeout(
      const Duration(seconds: 1),
      onTimeout: () => false,
    )) {
      return null;
    }
    final [channel as String, envelope as String] =
        frames.current! as List<Object?>;
    expect(channel, 'presence-room');
    final newline = envelope.indexOf('\n');
    expect(envelope.substring(0, newline), isEmpty, reason: 'no socket except');
    final frame =
        jsonDecode(envelope.substring(newline + 1)) as Map<String, Object?>;
    expect(frame['channel'], 'presence-room');
    final data = jsonDecode(frame['data']! as String) as Map<String, Object?>;
    return (frame['event']! as String, '${data['user_id']}');
  }

  test(
    'the members of a crashed worker are announced as removed to the others',
    () async {
      await call('broadcast', 'subscribe', {
        'channel': 'presence-room',
        'port': survivor.sendPort,
        'worker': 'daravel-worker-2',
      });
      await join('1.1', 'ana', 'daravel-worker-1');
      await join('2.1', 'bo', 'daravel-worker-2');
      // Cai has a tab on each worker: still a member after the crash.
      await join('1.2', 'cai', 'daravel-worker-1');
      await join('2.2', 'cai', 'daravel-worker-2');

      final watch = Stopwatch()..start();
      coordinator.forgetWorker('daravel-worker-1');

      expect(await nextFrame(), ('pusher_internal:member_removed', 'ana'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(await nextFrame(), isNull, reason: 'cai and bo stay');
      final users =
          (await call('channels', 'users', {'channel': 'presence-room'}))!
              as List<Object?>;
      expect(users, unorderedEquals(['bo', 'cai']));
    },
  );

  test('a crashed worker\'s own ports get nothing', () async {
    final crashed = ReceivePort();
    addTearDown(crashed.close);
    final received = <Object?>[];
    crashed.listen(received.add);
    await call('broadcast', 'subscribe', {
      'channel': 'presence-room',
      'port': crashed.sendPort,
      'worker': 'daravel-worker-1',
    });
    await join('1.1', 'ana', 'daravel-worker-1');
    coordinator.forgetWorker('daravel-worker-1');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, isEmpty);
  });

  test('without a broadcast service the members vanish silently', () {
    final service = ChannelMembershipService()
      ..handle('join', {
        'channel': 'presence-room',
        'socket': '1.1',
        'user_id': 'ana',
        'worker': 'daravel-worker-1',
      })
      ..forgetWorker('daravel-worker-1');
    expect(service.handle('users', {'channel': 'presence-room'}), isEmpty);
  });
}
