# Demo Horizon

[English](README.md) · Bahasa Indonesia

Supervisor queue di worker isolate beserta dashboard-nya, dengan
[`daravel_horizon`](../../packages/daravel_horizon): dua supervisor (`web` di
queue `default`, ukurannya mengikuti lama job menunggu, dan `reports` dengan
satu worker) serta tiga job: satu yang langsung selesai, satu yang butuh
setengah detik, dan satu yang gagal pada percobaan-percobaan pertamanya.

```bash
cp .env.example .env
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart migrate
dart run bin/server.dart          # Horizon berjalan di dalamnya (SERVER_EMBED_WORKERS=horizon)
curl -X POST 'http://127.0.0.1:8000/demo/dispatch?count=50'
```

Buka <http://127.0.0.1:8000/horizon>. Untuk menjalankan worker terpisah dari
server HTTP, kosongkan `SERVER_EMBED_WORKERS` dan jalankan
`dart run bin/dartisan.dart horizon` (tambahkan `--dashboard=:8090` agar
proses itu juga melayani dashboard). `dart run bin/dartisan.dart
schedule:work` mengambil snapshot metrik setiap lima menit untuk tab Metrics.

File SQLite di `.env.example` hanya untuk mencoba: di produksi gunakan
PostgreSQL atau MySQL. Di luar `APP_ENV=local` dashboard menjawab 403 sampai
gate `viewHorizon` mengizinkan user yang sedang login (dengan `withSession()`)
atau `HorizonDashboard.auth` mengizinkan request-nya (tanpa session):

```dart
// bootstrap/policies.dart, dengan session
gate.define('viewHorizon', (user, _) => user?.authIdentifier == 1);

// bootstrap/app.dart, tanpa session: header rahasia yang ditambahkan proxy
HorizonDashboard.auth(
  (request) =>
      constantTimeEquals(request.header('x-horizon-key') ?? '', horizonKey),
);
```

`dart test` memeriksa queue, API dashboard, dan 403.
