<!-- source: README.md sha256:80a272154ffe -->
# Daravel WebSocket Demo

[English](README.md) · Bahasa Indonesia

Contoh kecil dan lengkap untuk WebSocket dan broadcasting di Daravel: chat
dengan room, socket echo, dan endpoint HTTP yang mendorong pesan ke socket.
Contoh ini tidak memakai database, jadi paling cepat untuk dijalankan.

| Route | Yang ditunjukkan |
| :-- | :-- |
| `router.ws('/ws/echo', ...)` | Socket dua arah paling sederhana: menjawab `Echo: <message>` |
| `router.ws('/ws/chat/{room}', ...)` | Parameter route, dan `Broadcast.pipe` yang menyambungkan socket ke channel room; pesan dari satu client sampai ke semua client di room itu, dan antar-room tetap terpisah |
| `POST /api/chat/{room}/broadcast` | Controller, job, atau webhook yang mendorong pesan ke socket dengan `Broadcast.publish` |
| `GET /` | Client browser yang disajikan aplikasi itu sendiri, tanpa build step: ganti room, chat, coba HTTP push dan socket echo |

## Kebutuhan

- Dart SDK 3.13 atau lebih baru: `dart --version`. Repositori mengunci
  versinya di `.fvmrc`; dengan [fvm](https://fvm.app), tambahkan `fvm` di
  depan setiap perintah `dart` di bawah.
- Git dan browser.

## Menyiapkan

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # sekali, di root repositori

cd apps/websocket_demo
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # menulis APP_KEY ke .env
```

`dart pub get` dijalankan di root karena setiap contoh adalah anggota pub
workspace repositori: satu resolusi untuk semua paket.

## Menjalankan

```bash
dart run bin/server.dart                  # http://127.0.0.1:8000, Ctrl+C untuk berhenti
```

## Mencoba

1. Buka <http://127.0.0.1:8000> di dua tab browser.
2. Di salah satu tab, ganti nama `User_1` menjadi `User_2`.
3. Kirim pesan dari tab mana saja: pesan muncul di keduanya.
4. Ganti room di salah satu tab: pesan tidak lagi menyeberang antar-tab.
5. Klik **POST /api/chat/general/broadcast**, atau dorong dari terminal:

```bash
curl -s -X POST http://127.0.0.1:8000/api/chat/general/broadcast \
  -H 'Content-Type: application/json' \
  -d '{"sender": "Server", "message": "Halo dari curl"}'
```

Kedua tab harus terhubung ke server yang sama. Broadcast menyeberang antar-isolate
dalam satu proses (`dart run bin/dartisan.dart serve --isolates=4`); dua proses
terpisah, misalnya satu di port 8000 dan satu di port 8001, butuh
`daravel_redis` dan `withRedis()` agar pesannya tersambung.

## Menjalankan test

```bash
dart test                                 # di apps/websocket_demo
```

Test-nya membuka socket sungguhan: jawaban 426 untuk request biasa, echo,
pesan yang sampai ke setiap client di room, room yang tetap terpisah, HTTP
push, dan halamannya sendiri.

## Kalau ada masalah

| Gejala | Penyebab dan solusi |
| :-- | :-- |
| `pub get` menolak constraint SDK | Dart SDK lebih lama dari 3.13: perbarui, atau pakai `fvm dart` |
| `Address already in use` | Port 8000 dipakai program lain: ubah `APP_PORT` di `.env` |
| Pesan tidak sampai ke tab lain | Kedua tab ada di server atau room berbeda: pakai alamat, port, dan room yang sama |
| `426` pada `/ws/...` dari curl | Route WebSocket hanya menjawab upgrade WebSocket: pakai halamannya atau client WebSocket |

## Memakainya di luar repositori ini

Salin foldernya, hapus baris `resolution: workspace` dari `pubspec.yaml`,
ganti setiap constraint `any` pada paket Daravel dengan rilis terkini
(misalnya `^1.24.0`), lalu jalankan `dart pub get` di folder tersebut.

## Letak file

| Path | Isinya |
| :-- | :-- |
| `bin/server.dart` | Server HTTP dan WebSocket |
| `bootstrap/app.dart` | Aplikasi |
| `routes/web.dart` | Halaman dan kedua socket |
| `routes/api.dart` | HTTP push |
| `resources/views/chat_page.dart` | Halaman, HTML dan JavaScript biasa |
| `test/websocket_demo_test.dart` | Test |
