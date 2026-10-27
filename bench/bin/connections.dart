import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Opens [count] Pusher connections to a server, subscribes each to one
/// public channel, then times one event reaching all of them
/// (`bench/interop/connections.sh`):
///
/// ```bash
/// dart run bin/connections.dart --url=ws://127.0.0.1:18700/app/key1 \
///   --count=10000 --trigger=http://127.0.0.1:18700/api/publish --hold=20
/// ```
///
/// Prints `SUBSCRIBED <n> <ms>` once every connection is subscribed (the
/// moment to measure the server's memory), then `DELIVERED <n> <ms>`.
Future<void> main(List<String> args) async {
  String option(String name, String fallback) =>
      args
          .where((a) => a.startsWith('--$name='))
          .map((a) => a.substring(name.length + 3))
          .firstOrNull ??
      fallback;
  final url = option('url', 'ws://127.0.0.1:18700/app/key1');
  final count = int.parse(option('count', '10000'));
  final channel = option('channel', 'news');
  final trigger = option('trigger', 'http://127.0.0.1:18700/api/publish');
  final hold = Duration(seconds: int.parse(option('hold', '20')));
  // Connections from 127.0.0.2, .3, ...: each source address has its own
  // range of local ports (a few thousand on some systems, such as WSL).
  final sources = int.parse(option('sources', '8'));
  final clients = [
    for (var i = 0; i < sources; i++)
      HttpClient()
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(
              uri.host,
              uri.port,
              sourceAddress: InternetAddress('127.0.0.${i + 2}'),
            ),
  ];

  final sockets = <WebSocket>[];
  var subscribed = 0;
  var delivered = 0;
  final allSubscribed = Completer<void>();
  final allDelivered = Completer<void>();
  final watch = Stopwatch()..start();

  var opened = 0;
  Future<void> open() async {
    final socket = await WebSocket.connect(
      url,
      customClient: clients[opened++ % clients.length],
    );
    sockets.add(socket);
    socket.listen((message) {
      final frame = jsonDecode(message as String) as Map<String, Object?>;
      switch (frame['event']) {
        case 'pusher:connection_established':
          socket.add(
            jsonEncode({
              'event': 'pusher:subscribe',
              'data': {'channel': channel},
            }),
          );
        case 'pusher_internal:subscription_succeeded':
          if (++subscribed == count) {
            allSubscribed.complete();
          }
        case 'pusher:ping':
          socket.add(jsonEncode({'event': 'pusher:pong'}));
        default:
          if (frame['channel'] == channel && ++delivered == count) {
            allDelivered.complete();
          }
      }
    });
  }

  // 100 connections in flight at a time.
  for (var i = 0; i < count; i += 100) {
    await Future.wait([for (var j = i; j < i + 100 && j < count; j++) open()]);
  }
  await allSubscribed.future.timeout(const Duration(minutes: 5));
  stdout.writeln('SUBSCRIBED $subscribed ${watch.elapsedMilliseconds}');

  // Let the memory settle, then one event to everyone.
  await Future<void>.delayed(hold);
  final client = HttpClient();
  final fanout = Stopwatch()..start();
  await (await (await client.postUrl(
    Uri.parse(trigger),
  )).close()).drain<void>();
  client.close();
  await allDelivered.future.timeout(const Duration(minutes: 2));
  stdout.writeln('DELIVERED $delivered ${fanout.elapsedMilliseconds}');

  await Future<void>.delayed(const Duration(seconds: 2));
  await Future.wait([for (final socket in sockets) socket.close()]);
}
