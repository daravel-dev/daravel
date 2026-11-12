// daravel_reverb_client (Dart) against a Pusher protocol server: the
// scenarios of echo_test.mjs (Laravel Echo + pusher-js), run against
// Daravel and against Laravel Reverb (bench/interop/run.sh, A2 and C2).
//
//   PORT=18700 KEY=key1 [API=http://127.0.0.1:18700] dart run interop/echo_dart_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';

final Map<String, String> env = Platform.environment;
final String host = env['HOST'] ?? '127.0.0.1';
final String port = env['PORT']!;
final String key = env['KEY']!;
final String api = env['API'] ?? 'http://127.0.0.1:$port';
var failed = 0;
var passed = 0;

Echo echo(String token) => Echo.reverb(
  key: key,
  host: 'ws://$host:$port',
  auth: EchoAuth.bearer(() => token, endpoint: '$api/broadcasting/auth'),
);

Future<T> within<T>(Future<T> future, String what, [int ms = 5000]) =>
    future.timeout(
      Duration(milliseconds: ms),
      onTimeout: () => throw TimeoutException('timeout: $what'),
    );

Future<void> subscribed(EchoChannel channel) {
  final done = Completer<void>();
  channel.subscribedTo(() {
    if (!done.isCompleted) {
      done.complete();
    }
  });
  return done.future;
}

Future<Map<String, Object?>> first(EchoChannel channel, String event) {
  final done = Completer<Map<String, Object?>>();
  channel.listen(event, (data) {
    if (!done.isCompleted) {
      done.complete(data);
    }
  });
  return done.future;
}

Future<void> post(String path, [Map<String, String> headers = const {}]) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('$api/api$path'));
    headers.forEach(request.headers.set);
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close();
  }
}

void check(String name, bool ok, [Object? detail]) {
  ok ? passed++ : failed++;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'} $name${detail == null ? '' : ' ${jsonEncode(detail)}'}',
  );
}

Future<void> scenarios() async {
  final teo = echo('user-1');
  final ana = echo('user-2');

  // 1. Public channel, a custom event name (broadcastAs).
  final news = teo.channel('news');
  await within(subscribed(news), 'subscribe news');
  final published = first(news, '.published');
  await post('/publish');
  check(
    'public channel',
    (await within(published, 'published'))['title'] == 'Hello from Daravel',
  );

  // 2. Private channel through /broadcasting/auth; toOthers leaves Teo out.
  final teoOrders = teo.private('orders.7');
  final anaOrders = ana.private('orders.7');
  await within(
    Future.wait([subscribed(teoOrders), subscribed(anaOrders)]),
    'subscribe orders',
  );
  var teoGotIt = false;
  teoOrders.listen('OrderShipped', (_) => teoGotIt = true);
  final anaShipped = first(anaOrders, 'OrderShipped');
  await post('/ship/7', {
    'Authorization': 'Bearer user-1',
    'X-Socket-ID': teo.socketId!,
  });
  final shipped = await within(anaShipped, 'OrderShipped');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  check(
    r'private channel (App\Events\OrderShipped)',
    shipped['status'] == 'shipped',
    shipped,
  );
  check('toOthers (X-Socket-ID)', !teoGotIt);

  // 3. Whisper (client event) from Teo to Ana.
  final whisper = Completer<Map<String, Object?>>();
  anaOrders.listenForWhisper('typing', (data) {
    if (!whisper.isCompleted) {
      whisper.complete(data);
    }
  });
  teoOrders.whisper('typing', {'who': 'teo'});
  check('whisper', (await within(whisper.future, 'whisper'))['who'] == 'teo');

  // 4. Presence: here, joining, leaving.
  final teoHere = Completer<List<Map<String, Object?>>>();
  final joining = Completer<Map<String, Object?>>();
  final leaving = Completer<Map<String, Object?>>();
  teo.join('chat.1')
    ..here((m) => teoHere.isCompleted ? null : teoHere.complete(m))
    ..joining((m) => joining.isCompleted ? null : joining.complete(m))
    ..leaving((m) => leaving.isCompleted ? null : leaving.complete(m));
  final here = await within(teoHere.future, 'here');
  check(
    'presence here',
    here.length == 1 && here.single['name'] == 'Teo',
    here,
  );
  final anaHere = Completer<List<Map<String, Object?>>>();
  ana
      .join('chat.1')
      .here((m) => anaHere.isCompleted ? null : anaHere.complete(m));
  final both = await within(anaHere.future, 'ana here');
  check(
    'presence joining',
    (await within(joining.future, 'joining'))['name'] == 'Ana',
  );
  check(
    'presence members',
    (both.map((u) => '${u['name']}').toList()..sort()).join(',') == 'Ana,Teo',
    both,
  );
  ana.leave('chat.1');
  check(
    'presence leaving',
    (await within(leaving.future, 'leaving'))['name'] == 'Ana',
  );

  // 5. A notification on the user's private channel.
  final notification = Completer<Map<String, Object?>>();
  final user = teo.private('App.Models.User.1')
    ..notification(
      (n) => notification.isCompleted ? null : notification.complete(n),
    );
  await within(subscribed(user), 'subscribe user channel');
  await post('/notify');
  final n = await within(notification.future, 'notification');
  check(
    'notification',
    n['text'] == 'Welcome!' &&
        n['type'] == r'App\Notifications\Welcome' &&
        n['id'] != null,
    n,
  );

  // 6. A cache channel: a client that subscribes after the event gets it.
  // Teo holds the channel open first: Laravel Reverb keeps the last event
  // only of a channel that exists (Daravel keeps it either way).
  await within(subscribed(teo.channel('cache-prices')), 'subscribe cache');
  await post('/price');
  final late = echo('user-2');
  final cached = first(late.channel('cache-prices'), '.price.updated');
  check('cache channel', (await within(cached, 'cached event'))['price'] == 13);
  await late.disconnect();

  // 7. An end-to-end encrypted channel, opened with the shared_secret.
  final secretChannel = teo.encryptedPrivate('orders.7');
  await within(subscribed(secretChannel), 'subscribe encrypted');
  final secret = first(secretChannel, '.secret');
  await post('/secret');
  check(
    'encrypted channel',
    (await within(secret, 'encrypted event'))['code'] == '4821',
  );

  // 8. Ana may not listen to Teo's channel: the auth endpoint refuses.
  final refused = Completer<Object>();
  ana
      .private('App.Models.User.1')
      .error((e) => refused.isCompleted ? null : refused.complete(e));
  final error = await within(refused.future, 'auth error');
  check(
    'authorization refused',
    error is EchoAuthException && error.status == 403,
    '$error',
  );

  await teo.disconnect();
  await ana.disconnect();
}

Future<void> main() async {
  try {
    await scenarios();
  } on Object catch (error) {
    check('scenarios', false, '$error');
  }
  stdout.writeln('$passed passed, $failed failed');
  exit(failed == 0 ? 0 : 1);
}
