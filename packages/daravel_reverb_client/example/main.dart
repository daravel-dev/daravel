import 'package:daravel_reverb_client/daravel_reverb_client.dart';

/// Listens to a public and a private channel of a Laravel Reverb or
/// Daravel server, and joins a presence channel.
Future<void> main() async {
  final echo = Echo.reverb(
    key: 'app-key',
    host: 'ws://127.0.0.1:8080',
    auth: EchoAuth.bearer(
      () => 'user-1',
      endpoint: 'http://127.0.0.1:8000/broadcasting/auth',
    ),
  );
  echo.onConnectionStateChange.listen((state) => print('connection: $state'));
  echo.channel('news').listen('.announcement', (data) => print('news: $data'));
  echo
      .private('orders.7')
      .listen('OrderShipped', (data) => print('order: $data'));
  echo.join('chat.lobby')
    ..here((members) => print('here: $members'))
    ..joining((member) => print('joining: $member'))
    ..leaving((member) => print('leaving: $member'));
  await Future<void>.delayed(const Duration(seconds: 30));
  await echo.disconnect();
}
