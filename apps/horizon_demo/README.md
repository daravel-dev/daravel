# Horizon demo

English · [Bahasa Indonesia](README.id.md)

Queue supervisors on worker isolates and their dashboard, with
[`daravel_horizon`](../../packages/daravel_horizon): two supervisors (`web`
on the `default` queue, scaled by how long its jobs wait, and `reports` with
one worker) and three jobs: one that finishes at once, one that takes half a
second, and one that fails its first attempts.

```bash
cp .env.example .env
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart migrate
dart run bin/server.dart          # Horizon runs inside it (SERVER_EMBED_WORKERS=horizon)
curl -X POST 'http://127.0.0.1:8000/demo/dispatch?count=50'
```

Open <http://127.0.0.1:8000/horizon>. To run the workers apart from the HTTP
server, leave `SERVER_EMBED_WORKERS` empty and run
`dart run bin/dartisan.dart horizon` (add `--dashboard=:8090` to serve the
dashboard from that process). `dart run bin/dartisan.dart schedule:work`
takes a metric snapshot every five minutes for the Metrics tab.

The SQLite file of `.env.example` is for trying it out: in production use
PostgreSQL or MySQL. Outside `APP_ENV=local` the dashboard answers 403 until
the `viewHorizon` gate allows the signed-in user (with `withSession()`) or
`HorizonDashboard.auth` allows the request (without sessions):

```dart
// bootstrap/policies.dart, with sessions
gate.define('viewHorizon', (user, _) => user?.authIdentifier == 1);

// bootstrap/app.dart, without sessions: a secret header a proxy adds
HorizonDashboard.auth(
  (request) =>
      constantTimeEquals(request.header('x-horizon-key') ?? '', horizonKey),
);
```

`dart test` checks the queues, the dashboard's API and the 403.
