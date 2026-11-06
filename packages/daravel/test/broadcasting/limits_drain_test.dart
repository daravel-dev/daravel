import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

const String appKey = 'daravel-key';

void main() {
  Application? app;
  ServerEngine? engine;

  Future<void> boot(Map<String, String> env) async {
    app =
        Application.configure(
              basePath: Directory.systemTemp.createTempSync('daravel_r1_').path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'REVERB_APP_ID': '42',
              'REVERB_APP_KEY': appKey,
              'REVERB_APP_SECRET': 'daravel-secret',
              ...env,
            })
            .withBroadcasting()
            .withRouting(
              api: (r) {
                r
                  ..get(
                    '/stream',
                    (request) => Response.sse(
                      Stream<Object?>.periodic(
                        const Duration(seconds: 1),
                        (n) => n,
                      ),
                      heartbeat: null,
                    ),
                  )
                  ..post('/send', (request) async {
                    final rollback = request.query['rollback'] == '1';
                    try {
                      await DB.transaction(() async {
                        await Broadcast.send('news', ['news'], {'n': 1});
                        if (rollback) {
                          throw StateError('rolled back');
                        }
                      });
                    } on StateError {
                      // The transaction rolled back.
                    }
                    return Response.noContent();
                  });
              },
            )
            .create();
    await app!.boot();
    engine = ServerEngine(
      app!,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      kernel: app!.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    await engine!.start();
  }

  tearDown(() async {
    Clock.restore();
    await engine?.stop();
    await app?.shutdown();
    engine = null;
    app = null;
  });

  Future<_Client> connect() =>
      _Client.connect('ws://127.0.0.1:${engine!.port}/app/$appKey?protocol=7');

  Future<String> metrics() => app!.run(() => App.make<AppMetrics>().render());

  group('connection quota (REVERB_APP_MAX_CONNECTIONS)', () {
    test('a connection past it gets 4004 before connection_established, '
        'and a closed one frees its place', () async {
      await boot({'REVERB_APP_MAX_CONNECTIONS': '2'});
      final a = await connect();
      final b = await connect();
      final refused = await _Client.open(
        'ws://127.0.0.1:${engine!.port}/app/$appKey?protocol=7',
      );
      final first = await refused.next();
      expect(first['event'], 'pusher:error');
      expect(jsonDecode(first['data']! as String), {
        'code': 4004,
        'message': 'Application is over connection quota',
      });
      await refused.done;
      expect(await metrics(), contains('reason="connection_quota"} 1'));

      await a.close();
      final c = await connect();
      expect(c.established['event'], 'pusher:connection_established');
      await b.close();
      await c.close();
    });

    test('no quota by default', () async {
      await boot({});
      final clients = [for (var i = 0; i < 5; i++) await connect()];
      for (final client in clients) {
        await client.close();
      }
    });
  });

  group('rate limiting (REVERB_APP_RATE_LIMITING_*)', () {
    test('every message counts, ping included; past the limit 4301 until '
        'the window ends', () async {
      await boot({
        'REVERB_APP_RATE_LIMITING_ENABLED': 'true',
        'REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS': '3',
        'REVERB_APP_RATE_LIMIT_DECAY_SECONDS': '60',
      });
      Clock.freeze();
      final client = await connect();
      for (var i = 0; i < 3; i++) {
        client.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
        expect((await client.next())['event'], 'pusher:pong');
      }
      client.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      final refused = await client.next();
      expect(refused['event'], 'pusher:error');
      expect(jsonDecode(refused['data']! as String), {
        'code': 4301,
        'message': 'Rate limit exceeded',
      });
      expect(client.socket.closeCode, isNull, reason: 'not terminated');
      final text = await metrics();
      expect(text, contains('reverb_rejected_total{reason="rate_limit"} 1'));
      expect(text, contains('reverb_rate_limited_total{app="42"} 1'));

      Clock.travel(const Duration(seconds: 61));
      client.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      expect((await client.next())['event'], 'pusher:pong');
      await client.close();
    });

    test('REVERB_APP_RATE_LIMIT_TERMINATE closes the connection', () async {
      await boot({
        'REVERB_APP_RATE_LIMITING_ENABLED': 'true',
        'REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS': '1',
        'REVERB_APP_RATE_LIMIT_TERMINATE': 'true',
      });
      final client = await connect();
      client
        ..send({'event': 'pusher:ping', 'data': <String, Object?>{}})
        ..send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      expect((await client.next())['event'], 'pusher:pong');
      final refused = await client.next();
      final error =
          jsonDecode(refused['data']! as String) as Map<String, Object?>;
      expect(error['code'], 4301);
      await client.done;
      expect(client.socket.closeCode, 4301);
    });

    test('off by default', () async {
      await boot({});
      final client = await connect();
      for (var i = 0; i < 100; i++) {
        client.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      }
      for (var i = 0; i < 100; i++) {
        expect((await client.next())['event'], 'pusher:pong');
      }
      await client.close();
    });
  });

  group('drain', () {
    test('Pusher connections close spread over REVERB_DRAIN_SPREAD', () async {
      await boot({'REVERB_DRAIN_SPREAD': '2s'});
      final clients = [for (var i = 0; i < 200; i++) await connect()];
      final watch = Stopwatch()..start();
      final closedAt = <Duration>[];
      final all = Future.wait([
        for (final client in clients)
          client.done.then((_) => closedAt.add(watch.elapsed)),
      ]);
      await engine!.stop();
      await all.timeout(const Duration(seconds: 10));
      expect(clients.map((c) => c.socket.closeCode).toSet(), {
        WebSocketStatus.goingAway,
      });
      closedAt.sort();
      final spread = closedAt.last - closedAt.first;
      expect(spread, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
      expect(closedAt.last, lessThan(const Duration(seconds: 5)));
      engine = null;
    });

    test(
      'server-sent events get a random retry: of 1 to 5 s before the end',
      () async {
        await boot({});
        final client = HttpClient();
        addTearDown(client.close);
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${engine!.port}/api/stream'),
        );
        final response = await request.close();
        final body = StringBuffer();
        final read = response
            .transform(utf8.decoder)
            .listen(body.write)
            .asFuture<void>();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine!.stop();
        engine = null;
        await read.timeout(const Duration(seconds: 10));
        final retry = RegExp(r'retry: (\d+)\n').firstMatch('$body');
        expect(retry, isNotNull, reason: '$body');
        expect(int.parse(retry!.group(1)!), inInclusiveRange(1000, 5000));
        expect(
          '$body'.indexOf('retry:'),
          lessThan('$body'.indexOf('</stream>')),
        );
      },
    );
  });

  group('BROADCAST_AFTER_COMMIT', () {
    Future<void> post(String query) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${engine!.port}/api/send?$query'),
        );
        await (await request.close()).drain<void>();
      } finally {
        client.close();
      }
    }

    test('a broadcast in a transaction waits for the commit and is dropped '
        'on rollback', () async {
      await boot({});
      final client = await connect();
      await client.subscribe('news');
      await post('rollback=1');
      await post('rollback=0');
      final frame = await client.next();
      expect(frame['event'], 'news');
      expect(client.pending, isEmpty, reason: 'the rolled back one never came');
      await client.close();
    });

    test('false sends at once, rollback or not', () async {
      await boot({'BROADCAST_AFTER_COMMIT': 'false'});
      final client = await connect();
      await client.subscribe('news');
      await post('rollback=1');
      expect((await client.next())['event'], 'news');
      await client.close();
    });

    test('Channels names carry the Pusher prefixes', () {
      expect(Channels.private('orders.1'), 'private-orders.1');
      expect(Channels.presence('chat.2'), 'presence-chat.2');
      expect(Channels.encrypted('vault'), 'private-encrypted-vault');
    });
  });
}

/// A Pusher client speaking protocol 7, as pusher-js does.
final class _Client {
  _Client(this.socket) {
    socket.listen(
      (message) {
        final frame = jsonDecode(message as String) as Map<String, Object?>;
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(frame);
        } else {
          pending.add(frame);
        }
      },
      onDone: () {
        if (!_done.isCompleted) {
          _done.complete();
        }
      },
    );
  }

  /// Connected, without reading `connection_established`.
  static Future<_Client> open(String url) async =>
      _Client(await WebSocket.connect(url));

  static Future<_Client> connect(String url) async {
    final client = await open(url);
    client.established = await client.next();
    return client;
  }

  final WebSocket socket;
  final List<Map<String, Object?>> pending = [];
  final List<Completer<Map<String, Object?>>> _waiting = [];
  final Completer<void> _done = Completer<void>();
  late final Map<String, Object?> established;

  /// Completes when the server closed the connection.
  Future<void> get done => _done.future.timeout(const Duration(seconds: 10));

  Future<Map<String, Object?>> next() {
    if (pending.isNotEmpty) {
      return Future.value(pending.removeAt(0));
    }
    final waiting = Completer<Map<String, Object?>>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  Future<void> subscribe(String channel) async {
    send({
      'event': 'pusher:subscribe',
      'data': {'channel': channel},
    });
    final frame = await next();
    expect(frame['event'], 'pusher_internal:subscription_succeeded');
  }

  Future<void> close() async {
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
