# Daravel WebSocket Demo

English · [Bahasa Indonesia](README.id.md)

A small, complete example of WebSockets and broadcasting in Daravel: a chat
with rooms, an echo socket, and an HTTP endpoint that pushes to the sockets.

| Route | What it shows |
| :-- | :-- |
| `router.ws('/ws/echo', ...)` | The simplest duplex socket: it answers `Echo: <message>` |
| `router.ws('/ws/chat/{room}', ...)` | A route parameter, and `Broadcast.pipe` joining the socket to the room's channel; a message from one client reaches every client in the room, and rooms stay apart |
| `POST /api/chat/{room}/broadcast` | A controller, job or webhook pushing to the sockets with `Broadcast.publish` |
| `GET /` | A browser client served by the app itself, with no build step: switch rooms, chat, try the HTTP push and the echo socket |

## Run it

```bash
cd apps/websocket_demo
cp .env.example .env
dart run bin/dartisan.dart key:generate
dart run bin/server.dart
```

Open <http://127.0.0.1:8000> in two tabs, give one tab the name `User_2`, and send
a message from either.

Both tabs must reach the same server. Broadcasting crosses the isolates of one
process (`--isolates=N`); two separate processes, such as one on port 8000 and one
on port 8001, need `daravel_redis` and `withRedis()` to share messages.

## Test it

```bash
dart test
```

The tests open real sockets: the 426 answer to a plain request, the echo, a
message reaching every client of a room, rooms kept apart, the HTTP push, and the
page itself.

## Where things are

| Path | Holds |
| :-- | :-- |
| `bin/server.dart` | The HTTP and WebSocket server |
| `bootstrap/app.dart` | The application |
| `routes/web.dart` | The page and both sockets |
| `routes/api.dart` | The HTTP push |
| `resources/views/chat_page.dart` | The page, HTML and plain JavaScript |
| `test/websocket_demo_test.dart` | The tests |
