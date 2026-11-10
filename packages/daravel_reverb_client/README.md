<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_reverb_client

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_reverb_client/README.id.md)

A Pusher protocol 7 client after Laravel Echo, in pure Dart: it runs on the
VM, in Flutter (Android, iOS, desktop) and on the web, and talks to
**Laravel Reverb**, **Daravel** (`withBroadcasting()`, `daravel_reverb`) and
Pusher. It does not depend on the Daravel server, so a Flutter app can use
it against a Laravel backend as well.

```dart
import 'package:daravel_reverb_client/daravel_reverb_client.dart';

final echo = Echo.reverb(
  key: 'app-key',
  host: 'wss://ws.example.com',
  auth: EchoAuth.bearer(
    () async => tokenStore.token,
    endpoint: 'https://api.example.com/broadcasting/auth',
  ),
);

echo.channel('news').listen('.announcement', (data) => print(data));
echo.private('orders.42').listen('OrderShipped', (data) => print(data['status']));
echo.join('classroom.7')
  ..here((members) => print(members))
  ..joining((member) => print('joined: ${member['name']}'))
  ..leaving((member) => print('left: ${member['name']}'))
  ..whisper('typing', {'name': 'Teo'});
echo.encryptedPrivate('chat.9').listen('MessageSent', (data) => print(data));
echo.socketId; // the X-Socket-ID header of a request (toOthers)
```

- **Event names as Laravel Echo writes them:** `listen('OrderShipped')` is `App\Events\OrderShipped` (`namespace:`); `listen('.order.shipped')` is taken as it is.
- **Channels:** `channel`, `private`, `encryptedPrivate`, `join` (presence: `here`, `joining`, `leaving`, `members`); `whisper` and `listenForWhisper`; `notification` (Laravel's broadcast notifications); `listenToAll`, `stopListening`; `leave(name)`, `leaveChannel`, `leaveAll`. Cache channels (`cache-`) give a late subscriber the last event.
- **Authorization:** `EchoAuth.bearer` (a token), `EchoAuth.endpoint` (headers such as a session cookie) or `EchoAuth.custom`. A refused channel calls its `error` callback and `onError`; nothing is subscribed.
- **Encrypted channels** are opened with the `shared_secret` of the authorization (XSalsa20-Poly1305, as pusher-js). Whispers are not supported there.
- **The connection** pings after `activity_timeout` of silence, reconnects with exponential backoff and jitter, and subscribes again. `pusher:error` 4000–4099 stops it for good; 4200–4299 reconnects at once. `connectionState`, `onConnectionStateChange`, `disconnect()` and `connect()`.
- **`path:`** for a server with a prefix (`REVERB_SERVER_PATH`).

Tested against a Pusher server in the test's process, and in `bench/interop` against Daravel and Laravel Reverb 1.x with the scenarios that Laravel Echo and pusher-js pass.

## License

MIT.
