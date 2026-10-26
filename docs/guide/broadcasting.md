# Broadcasting

Daravel speaks the Pusher protocol, as Laravel Reverb does, on the port it
already serves HTTP on. Laravel Echo connects to it unchanged, Laravel can
broadcast through it, and Daravel can broadcast through a Reverb (or Pusher
Channels) instead. One `.env` serves both frameworks: the keys are
Laravel's.

## Serving Echo

```dotenv
REVERB_APP_ID=my-app
REVERB_APP_KEY=my-key            # public: Echo connects with it
REVERB_APP_SECRET=my-secret      # signs channel authorizations and API requests
```

```dart
Application.configure(basePath: '.')
    .withBroadcasting(
      channels: (channels) {
        channels.channel('App.Models.User.{id}',
            (user, p) => '${user.authIdentifier}' == p['id']);
        channels.channel('orders.{orderId}', (user, p) async =>
            (await Order.find(int.parse(p['orderId']!)))?['user_id'] ==
            user.authIdentifier);
        channels.channel('chat.{room}',
            (user, p) => {'id': user.authIdentifier, 'name': (user as User).name});
      },
    )
```

`channels` is Laravel's `routes/channels.php`: a pattern without the
`private-` or `presence-` prefix, `{placeholders}` that match up to the next
dot, and a callback that returns `false` to refuse, `true` for a private
channel, or the user's public details for a presence channel. The routes:

| Route | Purpose |
| :-- | :-- |
| `GET /app/{key}` | The WebSocket endpoint Echo connects to (Pusher protocol 7) |
| `POST /broadcasting/auth` | Signs private and presence channels, behind `authMiddleware` (`['auth']` by default) |
| `POST /apps/{id}/events`, `/apps/{id}/batch_events` | Publishing, for Laravel and other Pusher HTTP clients |
| `GET /apps/{id}/channels`, `/channels/{channel}`, `/channels/{channel}/users` | Channel information |

The front end is Laravel's:

```js
import Echo from 'laravel-echo';
import Pusher from 'pusher-js';

window.Echo = new Echo({
  broadcaster: 'reverb',
  key: import.meta.env.VITE_REVERB_APP_KEY,
  wsHost: 'api.example.com',
  wsPort: 443,
  forceTLS: true,
  enabledTransports: ['ws', 'wss'],
  authEndpoint: 'https://api.example.com/broadcasting/auth',
  auth: { headers: { Authorization: `Bearer ${token}` } },
  Pusher,
});

Echo.private(`orders.${orderId}`).listen('OrderShipped', (e) => { /* ... */ });
Echo.join(`chat.${room}`).here(users).joining(user).leaving(user);
Echo.private(`App.Models.User.${userId}`).notification((n) => { /* ... */ });
```

Connections, subscriptions and presence members are shared by every
worker isolate through the coordinator, so `APP_ISOLATES=4` behaves as one
server. They are not shared between machines: with several servers, put the
WebSocket on one, or use a Reverb with its Redis scaling.

## Broadcasting events

```dart
final class OrderShipped with ShouldBroadcast {
  OrderShipped(this.order);
  final Order order;

  @override
  List<String> broadcastOn() => ['private-orders.${order.id}'];

  @override
  Map<String, Object?> broadcastWith() => {'id': order.id, 'status': 'shipped'};
}

await Event.dispatch(OrderShipped(order));            // listeners, then broadcast
await Broadcast.event(OrderShipped(order).toOthers()); // Laravel's broadcast()->toOthers()
await Broadcast.send('price.updated', ['prices'], {'sku': 'A1', 'price': 12});
```

- Channel names carry Pusher's prefixes, as Laravel's `PrivateChannel` and
  `PresenceChannel` write them: `private-orders.7`, `presence-chat.1`.
- The event name is `App\Events\<Class>` unless `broadcastAs` says
  otherwise, which is what Echo's `.listen('OrderShipped')` expects; a
  custom name is listened for with a leading dot (`.listen('.shipped')`).
- Dart has no reflection, so `broadcastWith` says what to send (Laravel
  sends the public properties by default). `broadcastWhen` can skip it.
- `toOthers()` reads Echo's `X-Socket-ID` header from the current request
  and leaves that browser tab out.
- Broadcasting happens when the event is dispatched, not on a queue
  (Laravel's `ShouldBroadcastNow`).
- The `broadcast` notification channel sends Laravel's
  `BroadcastNotificationCreated` on `private-App.Models.User.1`, which
  Echo's `.notification()` receives ([Mail and notifications](mail.md#broadcast)).

## Where events go

`BROADCAST_CONNECTION` picks the destination:

| Value | Events go to |
| :-- | :-- |
| `daravel` (default) | this server's connections, on every isolate |
| `reverb` | a Laravel Reverb (or another Daravel) at `REVERB_HOST`, `REVERB_PORT`, `REVERB_SCHEME`, through its HTTP API |
| `pusher` | Pusher Channels: `PUSHER_APP_ID`, `PUSHER_APP_KEY`, `PUSHER_APP_SECRET`, `PUSHER_APP_CLUSTER` (or `PUSHER_HOST`) |
| `log` | the log |
| `null` | nowhere |

Laravel broadcasts through Daravel the same way: `BROADCAST_CONNECTION=reverb`
with `REVERB_HOST` pointing at the Daravel server, and the same app id, key
and secret. Daravel checks the request signatures as Pusher does, and also
refuses requests whose timestamp is more than ten minutes off, so a captured
request cannot be replayed (Reverb does not check the time).

## Origins and limits

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `REVERB_ALLOWED_ORIGINS` | `*` | Comma-separated host patterns that may connect (`app.example.com,*.example.com`) |
| `REVERB_APP_ACTIVITY_TIMEOUT` | `30` | Seconds of silence before a client pings; the server also pings |
| `REVERB_APP_MAX_MESSAGE_SIZE` | `10000` | The largest message a client may send, in bytes |

Client events (`client-*`, Echo's `whisper`) are forwarded only on private
and presence channels the sender has joined, as Pusher Channels requires.

## Verified against the real clients

`bench/interop/run.sh` (Linux and Docker) checks this against the software
it has to work with: `laravel-echo` and `pusher-js` from npm against Daravel
(public, private, `toOthers`, whispers, presence, notifications, a refused
authorization), Laravel 12 broadcasting through Daravel with
`pusher/pusher-php-server`, and Daravel broadcasting through Laravel Reverb,
with one or four worker isolates (`ISOLATES=4`).

## Lower level: Daravel's own channels

`Broadcast.publish`, `subscribe` and `pipe` move messages between worker
isolates without the Pusher protocol, for your own WebSocket or SSE routes
([Responses](responses.md#broadcasting-to-every-isolate)).
