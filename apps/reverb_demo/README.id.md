<!-- source: README.md sha256:6f3b78eac300 -->
# Demo Reverb

[English](README.md) · Bahasa Indonesia

Server WebSocket Pusher tersendiri, dengan
[`daravel_reverb`](../../packages/daravel_reverb): aplikasi HTTP
(`bin/server.dart`) menjawab `/broadcasting/auth` dari Echo dan mem-publish
lewat HTTP API Pusher ke `dartisan reverb:start`, yang melayani dua aplikasi
(aplikasi `REVERB_APP_*` dan `partner` dari `REVERB_APPS`), channel presence
(`presence-chat.{room}`), channel pesanan private dan terenkripsi end-to-end
(`private-orders.{id}`, `private-encrypted-orders.{id}`), serta dashboard
`/reverb`.

```bash
cp .env.example .env               # lalu isi REVERB_APP_KEY, _SECRET, dan kunci enkripsi
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart reverb:start   # ws://127.0.0.1:8080/app/{key}, 2 isolate
dart run bin/server.dart                  # http://127.0.0.1:8000
curl -X POST http://127.0.0.1:8000/demo/announce
curl -X POST http://127.0.0.1:8000/demo/ship/7
```

Laravel Echo tersambung dengan `broadcaster: 'reverb'`, `key` =
`REVERB_APP_KEY`, `wsHost: '127.0.0.1'`, `wsPort: 8080`, dan
`authEndpoint: 'http://127.0.0.1:8000/broadcasting/auth'` dengan
`Authorization: Bearer user-1` (Ana) atau `user-2` (Budi): dua pengguna demo
ini. Klien `partner-key` tidak pernah menerima event aplikasi demo.

Buka <http://127.0.0.1:8000/reverb> sebagai Ana (gate `viewReverb` di
`bootstrap/app.dart` hanya mengizinkan dia): koneksi per aplikasi dan
isolate, pesan per detik, penolakan, daftar aplikasi tanpa secret-nya, dan
tombol untuk `reverb:restart`. Angkanya dibaca dari `/metrics` server
WebSocket (`REVERB_METRICS_URL`).

`dart test` menjalankan kedua server dalam satu proses dan memeriksa
pengiriman, isolasi kedua aplikasi, otorisasi presence, dan gate dashboard.
