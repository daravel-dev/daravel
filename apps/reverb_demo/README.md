# Reverb demo

English · [Bahasa Indonesia](README.id.md)

A Pusher WebSocket server of its own, with
[`daravel_reverb`](../../packages/daravel_reverb): the HTTP application
(`bin/server.dart`) answers Echo's `/broadcasting/auth` and publishes through
the Pusher HTTP API to `dartisan reverb:start`, which serves two
applications (the one of `REVERB_APP_*` and `partner` from `REVERB_APPS`),
a presence channel (`presence-chat.{room}`), private and end-to-end
encrypted order channels (`private-orders.{id}`,
`private-encrypted-orders.{id}`), and the `/reverb` dashboard.

```bash
cp .env.example .env               # then set REVERB_APP_KEY, _SECRET and the encryption key
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart reverb:start   # ws://127.0.0.1:8080/app/{key}, 2 isolates
dart run bin/server.dart                  # http://127.0.0.1:8000
curl -X POST http://127.0.0.1:8000/demo/announce
curl -X POST http://127.0.0.1:8000/demo/ship/7
```

Laravel Echo connects with `broadcaster: 'reverb'`, `key` = `REVERB_APP_KEY`,
`wsHost: '127.0.0.1'`, `wsPort: 8080` and
`authEndpoint: 'http://127.0.0.1:8000/broadcasting/auth'` with
`Authorization: Bearer user-1` (Ana) or `user-2` (Budi): the demo's two
users. A client of `partner-key` never hears the demo application's events.

Open <http://127.0.0.1:8000/reverb> as Ana (the `viewReverb` gate in
`bootstrap/app.dart` lets only her in): connections per application and
isolate, messages per second, refusals, the applications without their
secrets, and a button for `reverb:restart`. The numbers are read from the
WebSocket server's `/metrics` (`REVERB_METRICS_URL`).

`dart test` runs both servers in one process and checks delivery, the
isolation of the two applications, presence authorization and the
dashboard's gate.
