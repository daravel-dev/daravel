# Responses and resources

Handlers can return `Response.json(data, status: 201)`, `Response.text`,
`Response.html`, `Response.redirect`, `Response.stream`,
`Response.noContent()`, any `JsonSerializable` or `Responsable`, maps,
lists, models and paginators. Dates serialize like Carbon's `toJSON()`:
UTC with microseconds, `2026-01-02T03:04:05.000000Z`.

`Response.json(data, phpCompatible: true)` writes the bytes of PHP's
`json_encode()` instead: `/` as `\/`, non-ASCII characters as `\u`
escapes, and an empty map as `[]` (an empty PHP array). Use it when a
client compares or signs the body a Laravel endpoint used to send.

## Cookies

```dart
final theme = request.cookie('theme', 'light');
return Response.json({'theme': theme})
    .withCookie('theme', 'dark', maxAge: const Duration(days: 30))
    .withoutCookie('legacy');
```

`request.cookies` holds every cookie, decoded like PHP's `$_COOKIE`.
`withCookie` adds a `Set-Cookie` header in the format Laravel sends, with
Laravel's defaults (`path=/`, `httponly`, `samesite=lax`); without
`maxAge` the cookie lasts for the browser session. Values are sent as
given: Laravel's `EncryptCookies` middleware has no counterpart yet, so a
cookie Laravel encrypted reads as its encrypted payload.

## API resources

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#resource -->
```dart
final class PostResource extends JsonResource<Post> {
  PostResource(super.resource);

  /// Documents the item for `dartisan openapi:generate` (`.returns(...)`).
  static const Map<String, Object?> schema = {
    'type': 'object',
    'properties': {
      'id': {'type': 'integer'},
      'title': {'type': 'string'},
      'published': {'type': 'boolean'},
    },
  };

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'title': resource.title,
    'published': resource.published,
  };
}
```
<!-- /include -->

- A single resource is wrapped in `{"data": {...}}`.
- `JsonResource.collection(items, PostResource.new)` wraps lists, and for
  paginators produces Laravel's `{data, links: {first, last, prev, next},
  meta}`, where `meta` is the paginator array without `data` and the URLs.
- `when`, `whenLoaded`, `mergeWhen`, `additional({...})` and
  `withMeta(request)` (Laravel's `with()`) are available.

## HTML

`package:daravel/html.dart` builds pages from Dart functions instead of Blade
templates. Text and attribute values are always escaped; markup that must be
written as is goes through `raw()`, like Blade's `{!! !!}`. A node returned
from a handler is sent as `text/html`:

```dart
import 'package:daravel/html.dart';

HtmlNode userCard(User user) => div(classes: 'card', [
  h2([user.name]),                                   // escaped
  p(classes: 'muted', [user.email]),
  if (user.isAdmin) span(classes: 'badge', ['Admin']),
]);

router.get('/users/{id}', (request) async => document(title: 'Profile', [
  mainEl([userCard(await User.query().findOrFail(request.param<int>('id')))]),
]));
```

Children are nodes, strings (escaped text), numbers, `null` (skipped) and
nested lists, so `if` and `for` work inside them. There are helpers for the
common elements (`div`, `span`, `p`, `h1`–`h3`, `a`, `ul`/`ol`/`li`, tables,
`form`, `input`, `label`, `button`, `img`, …), `el(tag, ...)` for any other,
and attributes where `true` writes a bare attribute (`required`) and
`false`/`null` leave it out. It is a separate import because names such as
`a`, `p` and `text` would clash with ordinary variables.

## Caching and compression

Laravel's `cache.headers` middleware sets `Cache-Control`, `ETag` and
`Last-Modified` on successful `GET`/`HEAD` responses and answers
`304 Not Modified` when the client's copy is current:

```dart
router.get('/catalog', catalog).middleware(const [
  'cache.headers:public;max_age=3600;etag',
]);
```

The options are Laravel's (`public`, `private`, `max_age`, `s_maxage`,
`must_revalidate`, `no_cache`, `no_store`, `immutable`, `etag`,
`last_modified=<unix time or date>`, ...) and the headers come out as
Laravel writes them (`Cache-Control: max-age=3600, public`; `private` is
added when neither `public`, `private` nor `s_maxage` is given). `etag`
hashes the body (MD5; Laravel uses xxh128, so the values differ but behave
the same). `If-None-Match` matches exactly, weakly (`W/`), from a list or
with `*`; `If-Modified-Since` is used only without it.

`CompressResponseMiddleware` gzips bodies of at least 1 KB with a text, JSON,
XML, SVG or JavaScript type for clients that send `Accept-Encoding: gzip`
(JSON usually shrinks by 70–90%), sets `Vary: Accept-Encoding` and turns a
strong `ETag` into a weak one. Streams are left alone. Behind a proxy that
already compresses (Caddy's `encode`, nginx's `gzip`), leave it out.

```dart
.withMiddleware((middleware) {
  middleware.use(const [CompressResponseMiddleware()]);
})
```
## Server-sent events and WebSockets

`Response.sse` is Laravel's `response()->eventStream()`: each item of the
stream goes out as soon as it is produced. A plain value is an `update` event
(JSON unless it is a string or number), and an `SseEvent` sets the event
name, `id` and `retry`. When the stream ends, `</stream>` is sent as Laravel
does, or pass `endStreamWith: null` to send nothing.

```dart
r.get('/api/orders/{id}/status', (request) async {
  final id = request.param<int>('id');
  return Response.sse(
    Stream.periodic(const Duration(seconds: 2), (_) => id)
        .asyncMap((id) async => (await Order.find(id))?.toJson())
        .take(30),
  );
});
```

The frames match Laravel's (`event: update`, `data: ...`), so a client
written against either backend works with both. On top of that:

- A `: keep-alive` comment is sent every 15 seconds while the stream is idle
  (`heartbeat:`), so proxies keep the connection open. That write is also how
  a closed tab is noticed, because TCP reports nothing on an idle
  connection. The source stream is then cancelled.
- `x-accel-buffering: no` and unbuffered writes keep nginx and `dart:io`
  from holding events back.
- On shutdown (SIGTERM, `ServerEngine.stop`) open streams end with their end
  event instead of holding the shutdown until its timeout, and `EventSource`
  reconnects to another instance. Read `request.header('last-event-id')` to
  resume from the last `id` it received.

`router.ws` upgrades a connection to a WebSocket after the route's
middleware has passed. `auth`, `throttle` and route parameters work as on
any route, and the handler runs in the request's scope, so `Auth.user()`
works there:

```dart
r.ws('/ws/rooms/{room}', (socket, request) async {
  final room = request.param<String>('room');
  socket.add(jsonEncode({'joined': room, 'user': await Auth.id()}));
  socket.listen((message) => socket.add('echo: $message'));
}).middleware(['auth:sanctum']);
```

A plain HTTP request to that path gets `426 Upgrade Required`. On shutdown
open sockets are closed with `1001` (going away). This is a raw WebSocket;
Laravel Echo connects through [Broadcasting](broadcasting.md). Clients that
ask for permessage-deflate get it; `r.ws(path, handler, compress: false)`
turns it off, which saves CPU and memory per connection when one message
goes to many sockets.

Both need a real connection. `TestClient` collects a response in full, so
test a finite `Response.sse` with it, and test WebSockets with `ServerEngine`
on port 0 and `WebSocket.connect`.

### Broadcasting to every isolate

With several isolates, the socket of one user is held by one of them, and
the request that has news for that user may run in another. `Broadcast`
publishes to a channel and every isolate delivers to its own listeners,
through the coordinator, without Redis:

```dart
r.ws('/ws/orders/{id}', (socket, request) =>
    Broadcast.pipe(socket, ['orders.${request.param<int>('id')}']));

// Anywhere: a controller, a job, a listener.
await Broadcast.publish('orders.7', {'status': 'shipped'});
```

`pipe` forwards a channel to a socket until it closes. `subscribe` gives
the messages as a stream, for SSE or anything else:

```dart
r.get('/orders/{id}/events', (request) async {
  final updates = await Broadcast.subscribe('orders.${request.param<int>('id')}');
  return Response.sse(updates.messages);
});
```

A message is a string, or anything else as JSON. It reaches only the
isolates that have a listener on the channel, in publish order, and is
not stored: a listener gets what is published after `subscribe` returns.
It stays within one server; for several machines, publish through
something they share, such as a database table or a queue.

For Laravel Echo clients, events go through the Pusher protocol instead
([Broadcasting](broadcasting.md)), which runs on top of these channels.

## Errors

Exceptions are rendered by the exception handler with Laravel's bodies. With
`APP_DEBUG=false` nothing internal leaks:

| Situation | Status | `message` |
| :-- | :-- | :-- |
| Validation failed | 422 | first error + `(and N more errors)`, plus `errors` |
| Not authenticated | 401 | `Unauthenticated.` |
| Gate / policy denied | 403 | `This action is unauthorized.` |
| Unknown route | 404 | `The route api/x could not be found.` |
| `findOrFail` / `firstOrFail` | 404 | `No query results for model [App\Models\Post] 1` |
| Wrong verb | 405 | `The DELETE method is not supported for route ... Supported methods: GET, HEAD.` |
| Body too large | 413 | `The POST data is too large.` |
| Rate limited | 429 | `Too Many Attempts.` |
| `abort(404)` without message | 404 | empty string, like Laravel |
| Anything else | 500 | `Server Error` |

These are Laravel 10 to 13's messages; `COMPAT_LARAVEL_VERSION=8` or `9`
answers with an older Laravel's ([Laravel coexistence](laravel-coexistence.md#older-laravel-versions)).

Register custom renderers with `withExceptions((e) => e.render<MyError>((error,
request) => Response.json({...}, status: 409)))`. A renderer may be
`async`: it can write an audit row or read a translation before it answers.
