import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('Broadcaster in one isolate', () {
    late Coordinator coordinator;
    late Broadcaster broadcaster;

    setUp(() {
      coordinator = createStandardCoordinator();
      broadcaster = Broadcaster(LocalCoordinatorChannel(coordinator));
    });

    tearDown(() => broadcaster.close());

    Map<String, Object?> stats() => coordinator.service('broadcast')!.stats();

    test('delivers to subscribers of the channel only', () async {
      final orders = await broadcaster.subscribe('orders.7');
      final other = await broadcaster.subscribe('orders.8');
      final received = <String>[];
      final ignored = <String>[];
      orders.messages.listen(received.add);
      other.messages.listen(ignored.add);

      expect(await broadcaster.publish('orders.7', {'status': 'shipped'}), 1);
      expect(await broadcaster.publish('orders.7', 'plain text'), 1);
      await pumpEventQueue();

      expect(received, ['{"status":"shipped"}', 'plain text']);
      expect(ignored, isEmpty);
    });

    test('an isolate leaves a channel with its last listener', () async {
      final first = await broadcaster.subscribe('room');
      final second = await broadcaster.subscribe('room');
      expect(stats()['channels'], 1);

      await first.cancel();
      expect(stats()['channels'], 1);
      expect(await broadcaster.publish('room', 'still here'), 1);

      await second.cancel();
      expect(stats()['channels'], 0);
      expect(await broadcaster.publish('room', 'nobody'), 0);
    });

    test('cancelling a stream subscription leaves too', () async {
      final subscription = await broadcaster.subscribe('room');
      final listener = subscription.messages.listen((_) {});
      await listener.cancel();
      await pumpEventQueue();
      expect(stats()['channels'], 0);
    });
  });

  test('fans out to every worker isolate through the coordinator', () async {
    final coordinator = createStandardCoordinator();
    final port = coordinator.listen();
    final inbox = ReceivePort();
    final messages = _Queue(inbox);
    final workers = <Isolate>[
      for (final name in ['a', 'b'])
        await Isolate.spawn(_worker, (name, port, inbox.sendPort)),
    ];
    // Each worker says it is subscribed before anything is published.
    expect({await messages.next, await messages.next}, {'a ready', 'b ready'});

    final publisher = Broadcaster(LocalCoordinatorChannel(coordinator));
    expect(await publisher.publish('chat', 'hello'), 2);
    expect(
      {await messages.next, await messages.next},
      {'a got hello', 'b got hello'},
    );

    for (final worker in workers) {
      worker.kill();
    }
    inbox.close();
    coordinator.close();
  });

  group('Broadcast.pipe over a real WebSocket', () {
    late Application app;
    late ServerEngine engine;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) {
              r.ws(
                '/orders/{id}',
                (socket, request) => Broadcast.pipe(socket, [
                  'orders.${request.param<int>('id')}',
                ]),
              );
              r.post('/orders/{id}/ship', (request) async {
                final id = request.param<int>('id');
                await Broadcast.publish('orders.$id', {'status': 'shipped'});
                return Response.noContent();
              });
            },
          )
          .create();
      await app.boot();
      engine = ServerEngine(
        app,
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          shutdownTimeout: Duration(seconds: 5),
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
    });

    tearDown(() async {
      await engine.stop();
      await app.shutdown();
    });

    test('a request publishes, the socket receives', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${engine.port}/api/orders/7',
      );
      final received = _Queue(socket);
      final channels = app.container.make<CoordinatorChannel>();
      // The socket subscribes once the upgrade is handled.
      Future<int> listening() async =>
          ((await channels.call('broadcast', 'publish', {
            'channel': 'orders.7',
            'message': 'probe',
          })) as int?) ??
          0;
      while (await listening() == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      while (await received.next != 'probe') {}

      final client = HttpClient();
      final response = await (await client.postUrl(
        Uri.parse('http://127.0.0.1:${engine.port}/api/orders/7/ship'),
      )).close();
      await response.drain<void>();
      client.close();
      expect(response.statusCode, 204);
      expect(jsonDecode(await received.next as String), {'status': 'shipped'});

      await socket.close();
      await received.cancel();
      // The closed socket unsubscribes.
      for (var i = 0; i < 200 && await listening() > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await listening(), 0);
    });
  });
}

/// A worker isolate: its own Broadcaster over a remote coordinator channel,
/// reporting what it receives on `chat`.
Future<void> _worker((String, SendPort, SendPort) setup) async {
  final (name, coordinator, report) = setup;
  final broadcaster = Broadcaster(RemoteCoordinatorChannel(coordinator));
  final subscription = await broadcaster.subscribe('chat');
  subscription.messages.listen((message) => report.send('$name got $message'));
  report.send('$name ready');
}

/// The messages of a stream, one `next` at a time.
final class _Queue {
  _Queue(Stream<Object?> stream) {
    _subscription = stream.listen((message) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(message);
      } else {
        _buffer.add(message);
      }
    });
  }

  late final StreamSubscription<Object?> _subscription;
  final List<Object?> _buffer = [];
  final List<Completer<Object?>> _waiting = [];

  Future<Object?> get next {
    if (_buffer.isNotEmpty) {
      return Future.value(_buffer.removeAt(0));
    }
    final waiting = Completer<Object?>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 10));
  }

  Future<void> cancel() => _subscription.cancel();
}
