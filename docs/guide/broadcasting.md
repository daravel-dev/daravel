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
server. Several servers (machines, or processes behind a load balancer)
share them through the database, as Reverb shares them through Redis; see
[Several servers](#several-servers).

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

## Cache and encrypted channels

A channel whose name starts with `cache-` (or `private-cache-`,
`presence-cache-`) keeps its last event for 30 minutes, as Pusher Channels
does: a client that subscribes later gets it right after
`subscription_succeeded`, or `pusher:cache_miss` when there is none.

```dart
await Broadcast.send('price.updated', ['cache-prices'], {'sku': 'A1', 'price': 13});
```

```js
Echo.channel('cache-prices').listen('.price.updated', (e) => { /* the last price */ });
```

`private-encrypted-` channels are end-to-end encrypted, as with Pusher:
set `REVERB_ENCRYPTION_MASTER_KEY_BASE64` (32 random bytes, base64:
`openssl rand -base64 32`) and listen with `Echo.encryptedPrivate`.
Each channel's key is derived from the master key, `/broadcasting/auth`
hands it to clients the channel admits, and events are sealed with
libsodium's `secretbox` before they leave the application, so the
WebSocket server only relays ciphertext. Clients cannot whisper on them.

```dart
await Broadcast.send('secret', ['private-encrypted-orders.7'], {'code': '4821'});
```

```js
Echo.encryptedPrivate('orders.7').listen('.secret', (e) => { /* decrypted */ });
```

The same key works with `BROADCAST_CONNECTION=reverb` or `pusher`: Laravel
(with `encryption_master_key_base64`) and Daravel encrypt the same way.

## Several servers

```dotenv
REVERB_SCALING_ENABLED=true
# REVERB_SCALING_CONNECTION=pgsql   # a connection other than the default
```

Add `CreateBroadcastingTables()` to `bootstrap/migrations.dart` and run
`dartisan migrate`. Each server then writes the frames it sends to
`broadcast_messages`, and every server reads the others' frames and hands
them to its own clients, so an event published on one server (by the HTTP
API, `Broadcast.send` or a whisper) reaches clients connected to any of
them. On PostgreSQL the servers wake each other with `NOTIFY`; on MySQL and
MariaDB they read every `REVERB_SCALING_POLL` (`100ms`).

Presence members are shared too, unlike Reverb, whose `here` lists only
the members on the same server: `here`, `member_added` (once per user,
whichever server the user's tabs are on) and the HTTP API's `channels`,
`channel` and `users` answer for the whole cluster, and so does the last
event of a cache channel. Each server sends a heartbeat every ten seconds;
the members of a server silent for 30 seconds (it crashed) stop counting
and are deleted a minute later.

Give each server a stable `REVERB_SERVER_ID` if the host name and process
id do not tell them apart. A load balancer needs no sticky sessions: a
client stays on the server its WebSocket reached.

## Origins and limits

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `REVERB_ALLOWED_ORIGINS` | `*` | Comma-separated host patterns that may connect (`app.example.com,*.example.com`) |
| `REVERB_APP_ACTIVITY_TIMEOUT` | `30` | Seconds of silence before a client pings; the server also pings |
| `REVERB_APP_MAX_MESSAGE_SIZE` | `10000` | The largest message a client may send, in bytes |

Client events (`client-*`, Echo's `whisper`) are forwarded only on private
and presence channels the sender has joined, as Pusher Channels requires.

## Capacity

`bench/interop/connections.sh` opens idle Echo connections against the AOT
build, all subscribed to one channel, and times one event reaching every
one of them. With 10 000 connections:

| | Memory (RSS) | One event to all |
| :-- | --: | --: |
| Daravel, 1 isolate | 11 MB idle, 189 MB loaded (about 18 KB per connection) | 0.62 s |
| Daravel, 4 isolates | 12 MB idle, 188 MB loaded | 0.43 s |
| `dart:io` alone (a bare `WebSocket` server) | 7 MB idle, 98 MB loaded (about 9 KB per connection) | 0.63 s |
| Laravel Reverb 1.12 | 54 MB idle, about 21 KB per connection (1 000 connections) | |

About half of each connection is `dart:io`'s own WebSocket. Reverb without
`ext-uv` or `ext-event` stops near 1 000 connections (PHP's
`stream_select`). The WebSocket runs without permessage-deflate, as
Reverb's does: compressing each frame for each connection made the same
event take 7.9 s.

## Verified against the real clients

`bench/interop/run.sh` (Linux and Docker) checks this against the software
it has to work with: `laravel-echo` and `pusher-js` from npm against Daravel
(public, private, `toOthers`, whispers, presence, notifications, cache and
encrypted channels, a refused authorization), two Daravel servers sharing one database, Laravel 12 broadcasting through Daravel with
`pusher/pusher-php-server`, and Daravel broadcasting through Laravel Reverb,
with one or four worker isolates (`ISOLATES=4`).

## Lower level: Daravel's own channels

`Broadcast.publish`, `subscribe` and `pipe` move messages between worker
isolates without the Pusher protocol, for your own WebSocket or SSE routes
([Responses](responses.md#broadcasting-to-every-isolate)).
