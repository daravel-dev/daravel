@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// What a client can send before it is authorized, and what the server
/// and its observers do with it: frames past the rate limit or the size
/// limit are counted but not shown to observers (the `--debug` log decodes
/// them), and no frame can overflow the log's masking.
void main() {
  late Coordinator coordinator;
  late Broadcaster broadcaster;
  late HttpServer http;
  late _Recorder recorder;
  final lines = <String>[];

  Future<void> serve(BroadcastConfig config) async {
    recorder = _Recorder();
    final pusher = PusherServer(
      config,
      broadcaster,
      LocalCoordinatorChannel(coordinator),
      observer: PusherObservers([recorder, PusherFrameLog(lines.add)]),
    );
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      unawaited(pusher.connect(socket, Request.fake(path: '/app/key'), 'key'));
    });
  }

  setUp(() {
    lines.clear();
    coordinator = createStandardCoordinator();
    broadcaster = Broadcaster(LocalCoordinatorChannel(coordinator));
  });

  tearDown(() async {
    await http.close(force: true);
    await broadcaster.close();
  });

  Future<_Client> connect() async {
    final client = _Client(
      await WebSocket.connect('ws://127.0.0.1:${http.port}/app/key'),
    );
    expect((await client.next())['event'], 'pusher:connection_established');
    return client;
  }

  test('a frame over the rate limit or the size limit is counted, and not '
      'shown to observers', () async {
    await serve(
      const BroadcastConfig(
        appId: '1',
        appKey: 'key',
        appSecret: 'secret',
        maxMessageSize: 200,
        rateLimiting: true,
        rateLimitMaxAttempts: 2,
      ),
    );
    final client = await connect();
    final big = jsonEncode({'event': 'client-x', 'data': 'a' * 400});
    client.socket.add(big);
    expect(_code(await client.next()), 4200);
    client.ping();
    expect((await client.next())['event'], 'pusher:pong');
    // Past the limit of two.
    client.socket.add(jsonEncode({'event': 'pusher:ping', 'data': 'third'}));
    expect(_code(await client.next()), 4301);
    expect(recorder.arrived, 3);
    expect(recorder.framesIn, hasLength(1), reason: 'only the ping');
    expect(lines.where((l) => l.contains('aaaa')), isEmpty);
    expect(lines.where((l) => l.contains('third')), isEmpty);
    await client.socket.close();
  });

  test('a deeply nested frame: refused, the connection stays, and the log '
      'masks without overflowing the stack', () async {
    await serve(
      const BroadcastConfig(appId: '1', appKey: 'key', appSecret: 'secret'),
    );
    final client = await connect();
    // 4 900 nested arrays, under 10 000 bytes: the log's walk overflowed.
    client.socket.add('${'[' * 4900}${']' * 4900}');
    expect(_code(await client.next()), 4200);
    client.ping();
    expect((await client.next())['event'], 'pusher:pong');
    expect(
      lines.where((l) => l.contains('[deeper than 32 levels]')),
      hasLength(1),
    );
    await client.socket.close();
  });

  group('PusherFrameLog.mask', () {
    test('a secret inside data that is JSON text after white space, or an '
        'array, is masked', () {
      for (final data in [
        ' {"auth":"s3cret-1"}',
        '\n\t{"channel_data":"s3cret-2"}',
        '[{"secret":"s3cret-3"}]',
        ' [ {"app_secret":"s3cret-4"} ]',
      ]) {
        final shown = PusherFrameLog.mask(
          jsonEncode({'event': 'client-x', 'data': data}),
        );
        expect(shown, isNot(contains('s3cret')), reason: data);
        expect(shown, contains('***'), reason: data);
      }
    });

    test('deeper than 32 levels is not shown, a secret there neither', () {
      var value = <String, Object?>{'secret': 'deep-s3cret'};
      for (var i = 0; i < 40; i++) {
        value = {'n': value};
      }
      final shown = PusherFrameLog.mask(jsonEncode(value));
      expect(shown, contains('[deeper than 32 levels]'));
      expect(shown, isNot(contains('deep-s3cret')));
      expect(
        PusherFrameLog.mask('${'[' * 20000}${']' * 20000}'),
        contains('[deeper than 32 levels]'),
      );
    });
  });
}

int _code(Map<String, Object?> frame) {
  expect(frame['event'], 'pusher:error');
  return (jsonDecode(frame['data']! as String) as Map)['code']! as int;
}

final class _Recorder extends PusherObserver {
  int arrived = 0;
  final List<Object?> framesIn = [];

  @override
  void received(String app) => arrived++;

  @override
  void frame(String app, String socketId, String direction, Object? payload) {
    if (direction == 'in') {
      framesIn.add(payload);
    }
  }
}

final class _Client {
  _Client(this.socket) {
    socket.listen((message) {
      final frame = jsonDecode(message as String) as Map<String, Object?>;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        _frames.add(frame);
      }
    });
  }

  final WebSocket socket;
  final List<Map<String, Object?>> _frames = [];
  final List<Completer<Map<String, Object?>>> _waiting = [];

  Future<Map<String, Object?>> next() {
    if (_frames.isNotEmpty) {
      return Future.value(_frames.removeAt(0));
    }
    final waiting = Completer<Map<String, Object?>>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void ping() => socket.add(
    jsonEncode({'event': 'pusher:ping', 'data': <String, Object?>{}}),
  );
}
