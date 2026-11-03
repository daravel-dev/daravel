# Daravel WebSocket Demo

English · [Bahasa Indonesia](README.id.md)

A small, complete example of WebSockets and broadcasting in Daravel: a chat
with rooms, an echo socket, and an HTTP endpoint that pushes to the sockets.
It has no database, so it is the quickest example to run.

| Route | What it shows |
| :-- | :-- |
| `router.ws('/ws/echo', ...)` | The simplest duplex socket: it answers `Echo: <message>` |
| `router.ws('/ws/chat/{room}', ...)` | A route parameter, and `Broadcast.pipe` joining the socket to the room's channel; a message from one client reaches every client in the room, and rooms stay apart |
| `POST /api/chat/{room}/broadcast` | A controller, job or webhook pushing to the sockets with `Broadcast.publish` |
| `GET /` | A browser client served by the app itself, with no build step: switch rooms, chat, try the HTTP push and the echo socket |

## Requirements

- The Dart SDK 3.13 or newer: `dart --version`. The repository pins the
  version in `.fvmrc`; with [fvm](https://fvm.app), put `fvm` before every
  `dart` command below.
- Git and a browser.

## Set it up

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # once, at the root of the repository

cd apps/websocket_demo
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # writes APP_KEY into .env
```

`dart pub get` runs at the root because every example is a member of the
repository's pub workspace: one resolution for all packages.

## Run it

```bash
dart run bin/server.dart                  # http://127.0.0.1:8000, Ctrl+C stops it
```

## Try it

1. Open <http://127.0.0.1:8000> in two browser tabs.
2. In one tab, change the name `User_1` to `User_2`.
3. Send a message from either tab: it appears in both.
4. Change the room in one tab: messages no longer cross between the tabs.
5. Click **POST /api/chat/general/broadcast**, or push from a terminal:

```bash
curl -s -X POST http://127.0.0.1:8000/api/chat/general/broadcast \
  -H 'Content-Type: application/json' \
  -d '{"sender": "Server", "message": "Hello from curl"}'
```

Both tabs must reach the same server. Broadcasting crosses the isolates of one
process (`dart run bin/dartisan.dart serve --isolates=4`); two separate
processes, such as one on port 8000 and one on port 8001, need
`daravel_redis` and `withRedis()` to share messages.

## Test it

```bash
dart test                                 # in apps/websocket_demo
```

The tests open real sockets: the 426 answer to a plain request, the echo, a
message reaching every client of a room, rooms kept apart, the HTTP push, and the
page itself.

## When something goes wrong

| Symptom | Cause and fix |
| :-- | :-- |
| `pub get` rejects the SDK constraint | The Dart SDK is older than 3.13: upgrade it, or use `fvm dart` |
| `Address already in use` | Another program has port 8000: set `APP_PORT` in `.env` |
| A message does not reach the other tab | The tabs are on different servers or rooms: use the same address, port and room |
| `426` on `/ws/...` from curl | A WebSocket route answers only a WebSocket upgrade: use the page or a WebSocket client |

## Use it outside this repository

Copy the folder, remove the line `resolution: workspace` from
`pubspec.yaml`, change each `any` constraint on a Daravel package to the
current release (for example `^1.24.0`), and run `dart pub get` in the
folder.

## Where things are

| Path | Holds |
| :-- | :-- |
| `bin/server.dart` | The HTTP and WebSocket server |
| `bootstrap/app.dart` | The application |
| `routes/web.dart` | The page and both sockets |
| `routes/api.dart` | The HTTP push |
| `resources/views/chat_page.dart` | The page, HTML and plain JavaScript |
| `test/websocket_demo_test.dart` | The tests |
