import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Lets a request through only with `x-allowed`, and leaves a value for the
/// handler (it runs in the same request scope).
final class _Gate implements Middleware {
  const _Gate();
  @override
  Future<Response> handle(Request request, Next next) {
    final who = request.header('x-allowed');
    if (who == null) {
      return Future.value(
        Response.json(const {'message': 'Unauthenticated.'}, status: 401),
      );
    }
    request.attributes['who'] = who;
    return next(request);
  }
}

/// Reads until [needle] has arrived (TCP may split or join chunks).
Future<String> readUntil(StreamIterator<String> chunks, String needle) async {
  final seen = StringBuffer();
  while (!seen.toString().contains(needle)) {
    if (!await chunks.moveNext()) {
      fail('stream ended before "$needle"; got "$seen"');
    }
    seen.write(chunks.current);
  }
  return seen.toString();
}

Future<String> readToEnd(StreamIterator<String> chunks) async {
  final rest = StringBuffer();
  while (await chunks.moveNext()) {
    rest.write(chunks.current);
  }
  return rest.toString();
}

void main() {
  group('SseEvent', () {
    test('frames follow the EventSource format', () {
      expect(const SseEvent('hi').encode(), 'event: update\ndata: hi\n\n');
      expect(
        const SseEvent(
          {'a': 1},
          event: 'tick',
          id: '7',
          retry: Duration(seconds: 3),
        ).encode(),
        'event: tick\nid: 7\nretry: 3000\ndata: {"a":1}\n\n',
      );
      expect(
        const SseEvent('one\ntwo').encode(),
        'event: update\ndata: one\ndata: two\n\n',
      );
      expect(const SseEvent(42).encode(), 'event: update\ndata: 42\n\n');
      expect(const SseEvent.comment('keep-alive').encode(), ': keep-alive\n\n');
      expect(const SseEvent.comment('').encode(), ':\n\n');
    });
  });

  group('over a real socket', () {
    late Application app;
    late ServerEngine engine;
    late StreamController<Object?> source;
    late Completer<void> cancelled;

    setUp(() async {
      source = StreamController<Object?>();
      cancelled = Completer<void>();
      source.onCancel = () {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      };
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) {
              r.get('/events', (_) => Response.sse(source.stream));
              r.get(
                '/watched',
                (_) => Response.sse(
                  source.stream,
                  heartbeat: const Duration(milliseconds: 50),
                ),
              );
              r.get(
                '/quiet',
                (_) => Response.sse(
                  StreamController<Object?>().stream,
                  heartbeat: const Duration(milliseconds: 50),
                  endStreamWith: null,
                ),
              );
              r.ws('/rooms/{room}', (socket, request) {
                socket.add('joined ${request.param<String>('room')}');
                socket.listen((message) => socket.add('echo: $message'));
              });
              r
                  .ws('/private', (socket, request) {
                    socket.add('hello ${request.attributes['who']}');
                  })
                  .middleware(const [_Gate()]);
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
          shutdownTimeout: Duration(seconds: 10),
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

    Uri http(String path) => Uri.parse('http://127.0.0.1:${engine.port}$path');
    String ws(String path) => 'ws://127.0.0.1:${engine.port}$path';

    Future<(HttpClientResponse, StreamIterator<String>)> open(
      HttpClient client,
      String path,
    ) async {
      final request = await client.getUrl(http(path));
      final response = await request.close();
      return (response, StreamIterator(response.transform(utf8.decoder)));
    }

    test('events arrive as they are sent, then the end event', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final (response, chunks) = await open(client, '/api/events');
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      expect(response.headers.value('cache-control'), 'no-cache');
      expect(response.headers.value('x-accel-buffering'), 'no');

      // The headers came at once (an empty comment opens the stream), and
      // nothing is buffered: each event shows up while the stream is open.
      expect(await readUntil(chunks, ':\n\n'), ':\n\n');
      source.add({'n': 1});
      expect(
        await readUntil(chunks, '{"n":1}\n\n'),
        'event: update\ndata: {"n":1}\n\n',
      );
      source.add(const SseEvent('done soon', event: 'status'));
      expect(
        await readUntil(chunks, 'done soon\n\n'),
        'event: status\ndata: done soon\n\n',
      );
      await source.close();
      expect(await readToEnd(chunks), 'event: update\ndata: </stream>\n\n');
    });

    test(
      'a client that goes away cancels the source at the next heartbeat',
      () async {
        final client = HttpClient();
        final (_, chunks) = await open(client, '/api/watched');
        source.add('first');
        await readUntil(chunks, 'data: first');
        client.close(force: true);
        await cancelled.future.timeout(const Duration(seconds: 5));
      },
    );

    test('an idle stream sends heartbeats', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final (_, chunks) = await open(client, '/api/quiet');
      expect(await readUntil(chunks, ': keep-alive\n\n'), contains('keep'));
    });

    test(
      'shutdown ends open streams instead of waiting for the timeout',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final (_, chunks) = await open(client, '/api/events');
        source.add('x');
        await readUntil(chunks, 'data: x');
        final watch = Stopwatch()..start();
        await engine.stop();
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(await readToEnd(chunks), contains('data: </stream>'));
      },
    );

    test('WebSocket routes upgrade after their middleware', () async {
      final socket = await WebSocket.connect(ws('/api/rooms/lobby'));
      final messages = StreamIterator(socket.cast<String>());
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, 'joined lobby');
      socket.add('hi');
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, 'echo: hi');
      expect(engine.openWebSockets, 1);
      await socket.close();

      // The middleware runs first and shares its scope with the handler.
      await expectLater(
        WebSocket.connect(ws('/api/private')),
        throwsA(isA<WebSocketException>()),
      );
      final allowed = await WebSocket.connect(
        ws('/api/private'),
        headers: {'x-allowed': 'teo'},
      );
      expect(await allowed.first, 'hello teo');
      await allowed.close();
    });

    test('a plain request to a WebSocket route is 426', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final (response, _) = await open(client, '/api/rooms/lobby');
      expect(response.statusCode, 426);
      expect(response.headers.value('upgrade'), 'websocket');
      // In process too.
      (await TestClient(app).get('/api/rooms/lobby')).assertStatus(426);
    });

    test('shutdown closes WebSockets with 1001 (going away)', () async {
      final socket = await WebSocket.connect(ws('/api/rooms/a'));
      addTearDown(socket.close);
      final done = socket.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await engine.stop();
      await done;
      expect(socket.closeCode, WebSocketStatus.goingAway);
    });
  });
}
