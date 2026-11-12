import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/commands.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:args/command_runner.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final String secret = 's' * 32;

/// One directory for the process: a top-level initializer runs again in
/// every isolate, and the workers must share the signal store's files.
final String base = (Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}'
  'daravel_reverb_client_roll_$pid',
)..createSync(recursive: true)).path;

/// The supervisor `serveWith` started, kept by a hook (hooks run in the
/// main isolate, which is the test's).
Supervisor? servedSupervisor;

final class Member implements Authenticatable {
  const Member(this.id, this.name);
  final int id;
  final String name;
  @override
  Object get authIdentifier => id;
  @override
  String get authIdentifierName => 'id';
  @override
  String? get authPassword => null;
  @override
  String get authPasswordName => 'password';
  @override
  String? get rememberToken => null;
}

/// The application: top-level, so worker isolates can build it. Bearer
/// `user-1`/`user-2` are users 1 and 2; `orders.7` is theirs, and
/// `room.{id}` is a presence channel.
Application rollingApp() => Application.configure(basePath: base)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_DATABASE': '$base${Platform.pathSeparator}rolling.sqlite',
      'QUEUE_SIGNAL_STORE': 'file',
      'REVERB_APP_ID': '42',
      'REVERB_APP_KEY': 'key-a',
      'REVERB_APP_SECRET': secret,
      'REVERB_DRAIN_SPREAD': '200ms',
    })
    .withLogLevel(LogLevel.critical)
    .withAuth((auth) {
      auth.register(
        'token',
        ClosureGuard<Member>(
          name: 'token',
          resolver: (request) => switch (request.bearerToken()) {
            'user-1' => const Member(1, 'Teo'),
            'user-2' => const Member(2, 'Ana'),
            _ => null,
          },
        ),
      );
    })
    .withBroadcasting(
      channels: (channels) {
        channels
          ..channel('orders.{id}', (user, p) => p['id'] == '7')
          ..channel('room.{id}', (user, p) => {'name': (user as Member).name});
      },
    )
    .withReverb()
    .withSupervisorHook((_, supervisor) {
      servedSupervisor = supervisor;
      return null;
    })
    .create();

Future<int?> dartisan(List<String> args) {
  final runner = CommandRunner<int>('dartisan', 'test');
  for (final command in reverbCommands) {
    runner.addCommand(command(rollingApp));
  }
  return runner.run(args);
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// One user's client, with what it saw.
final class Client {
  Client(int port, String token, this.name) {
    echo = Echo.reverb(
      key: 'key-a',
      host: 'ws://127.0.0.1:$port',
      auth: EchoAuth.bearer(
        () => token,
        endpoint: 'http://127.0.0.1:$port/broadcasting/auth',
      ),
      reconnectBase: const Duration(milliseconds: 50),
      reconnectMax: const Duration(milliseconds: 400),
      connector: (uri) {
        final channel = WebSocketChannel.connect(uri);
        sockets.add(channel);
        return channel;
      },
    );
    echo.onConnectionStateChange.listen(states.add);
    echo
        .channel('news')
        .subscribedTo(() => subscribed['news'] = subscribed['news']! + 1)
        .listen('.news.posted', (data) => received.add('news:${data['n']}'));
    echo
        .private('orders.7')
        .subscribedTo(() => subscribed['orders'] = subscribed['orders']! + 1)
        .listen('.news.posted', (data) => received.add('orders:${data['n']}'));
    room = echo.join('room.1')
      ..subscribedTo(() => subscribed['room'] = subscribed['room']! + 1)
      ..listen('.news.posted', (data) => received.add('room:${data['n']}'));
  }

  final String name;
  late final Echo echo;
  late final EchoPresenceChannel room;
  final List<WebSocketChannel> sockets = [];
  final List<EchoConnectionState> states = [];
  final Map<String, int> subscribed = {'news': 0, 'orders': 0, 'room': 0};
  final List<String> received = [];

  Set<String> get memberNames => {
    for (final member in room.members) '${member['name']}',
  };

  bool get allSubscribed =>
      echo.connectionState == EchoConnectionState.connected &&
      echo.channels.values.every((channel) => channel.subscribed);
}

Future<void> until(
  bool Function() done,
  String what, {
  Duration within = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// `daravel_reverb_client` against a real Daravel server in supervisor mode
/// (two workers), not a fake: `reverb:restart` closes each connection with
/// 1001 (going away) while its worker drains, and the client reconnects,
/// subscribes its public, private and presence channels again, sees both
/// members again, and receives what is published afterwards.
void main() {
  test('a rolling restart: 1001, reconnect, channels and presence back, '
      'events delivered', () async {
    final port = await freePort();
    servedSupervisor = null;
    final served = Application.serveWith(
      reverbServer(rollingApp, auth: true),
      host: '127.0.0.1',
      port: port,
      isolates: 2,
      embedQueue: false,
      embedScheduler: false,
      embedWorkers: const [],
      processes: 1,
    );
    Object? failed;
    var ended = false;
    unawaited(
      served.then(
        (_) => ended = true,
        onError: (Object error) {
          failed = error;
          ended = true;
        },
      ),
    );
    final up = DateTime.now().add(const Duration(seconds: 60));
    while (servedSupervisor == null && !ended && DateTime.now().isBefore(up)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(failed, isNull, reason: 'serveWith failed');
    final supervisor = servedSupervisor;
    if (supervisor == null) {
      fail('the supervisor hook did not run');
    }
    addTearDown(() async {
      await supervisor.stop();
      await served;
    });

    final teo = Client(port, 'user-1', 'Teo');
    final ana = Client(port, 'user-2', 'Ana');
    final clients = [teo, ana];
    addTearDown(() async {
      for (final client in clients) {
        await client.echo.disconnect();
      }
    });
    for (final client in clients) {
      await until(() => client.allSubscribed, '${client.name} subscribed');
    }
    for (final client in clients) {
      await until(
        () => client.memberNames.containsAll({'Teo', 'Ana'}),
        '${client.name} seeing both members',
      );
    }
    final before = {for (final c in clients) c.name: c.echo.socketId};

    var sent = 0;
    Future<void> publish() async {
      sent++;
      final body = jsonEncode({
        'name': 'news.posted',
        'channels': ['news', 'private-orders.7', 'presence-room.1'],
        'data': jsonEncode({'n': sent}),
      });
      const path = '/apps/42/events';
      final query = PusherSignature.signRequest(
        key: 'key-a',
        secret: secret,
        method: 'POST',
        path: path,
        body: body,
      );
      final http = HttpClient();
      try {
        final request = await http.postUrl(
          Uri.http('127.0.0.1:$port', path, query),
        );
        request.headers.contentType = ContentType.json;
        request.write(body);
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 200, reason: 'publish $sent');
      } finally {
        http.close();
      }
    }

    await publish();
    for (final client in clients) {
      await until(
        () => client.received.toSet().containsAll({
          'news:1',
          'orders:1',
          'room:1',
        }),
        '${client.name} receiving event 1',
      );
    }

    expect(await dartisan(['reverb:restart']), 0);

    for (final client in clients) {
      await until(
        () => client.states.contains(EchoConnectionState.unavailable),
        '${client.name} losing its connection',
        within: const Duration(seconds: 30),
      );
      // The first socket was closed by the draining worker with 1001.
      expect(
        client.sockets.first.closeCode,
        1001,
        reason: '${client.name}: going away, not a crash',
      );
    }
    for (final client in clients) {
      await until(
        () =>
            client.allSubscribed &&
            client.subscribed.values.every((n) => n >= 2),
        '${client.name} subscribed again',
        within: const Duration(seconds: 30),
      );
      expect(client.echo.socketId, isNot(before[client.name]));
    }
    for (final client in clients) {
      await until(
        () => client.memberNames.containsAll({'Teo', 'Ana'}),
        '${client.name} seeing both members again',
      );
    }

    // A publish reaches both clients on each channel. While the second
    // worker still drains, a client may be between connections (Pusher
    // delivers at most once), so publish until one event reaches both.
    bool got(Client client, int n) => client.received.toSet().containsAll({
      'news:$n',
      'orders:$n',
      'room:$n',
    });
    final settled = DateTime.now().add(const Duration(seconds: 30));
    var delivered = false;
    while (!delivered && DateTime.now().isBefore(settled)) {
      await publish();
      final wait = DateTime.now().add(const Duration(seconds: 1));
      while (!clients.every((c) => got(c, sent)) &&
          DateTime.now().isBefore(wait)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      delivered = clients.every((c) => got(c, sent));
    }
    expect(
      delivered,
      isTrue,
      reason: 'an event after the restart reached both',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
