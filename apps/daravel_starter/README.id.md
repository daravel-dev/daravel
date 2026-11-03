<!-- source: README.md sha256:d240f0d6d1b2 -->
# Daravel starter

[English](README.md) · Bahasa Indonesia

Aplikasi referensi Daravel, sekaligus hasil `dartisan new`: halaman
welcome, autentikasi token (register, login, logout, me), API users dengan
validasi, policy dan resource, migration, seeder, factory, serta test.
Test-nya adalah spesifikasi end-to-end framework, jadi semua yang
ditunjukkan di sini diperiksa di setiap commit.

| Route | Fungsinya |
| :-- | :-- |
| `GET /` | Halaman welcome |
| `GET /api/ping` | Jawaban kesehatan untuk monitor |
| `POST /api/auth/register` | Membuat user dan mengembalikan bearer token |
| `POST /api/auth/login` | Mengembalikan bearer token untuk email dan password (5 percobaan per menit) |
| `GET /api/auth/me`, `POST /api/auth/logout` | User saat ini; mencabut token |
| `GET /api/users`, `GET /api/users/{id}`, `POST /api/users`, `PATCH /api/users/{id}` | API users, dengan pagination seperti Laravel |
| `GET /docs/api` | Referensi API langsung, aktif selama `APP_ENV=local` |
| `GET /up` | Route kesehatan |

## Kebutuhan

- Dart SDK 3.13 atau lebih baru: `dart --version`. Repositori mengunci
  versinya di `.fvmrc`; dengan [fvm](https://fvm.app), tambahkan `fvm` di
  depan setiap perintah `dart` di bawah.
- Git. SQLite tidak perlu dipasang: paket `sqlite3` sudah membawanya.

## Menyiapkan

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # sekali, di root repositori

cd apps/daravel_starter
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # menulis APP_KEY ke .env
dart run bin/dartisan.dart migrate --seed # database/database.sqlite dan 11 user
```

`dart pub get` dijalankan di root karena setiap contoh adalah anggota pub
workspace repositori: satu resolusi untuk semua paket.

## Menjalankan

```bash
dart run bin/dartisan.dart serve          # http://127.0.0.1:8000, Ctrl+C untuk berhenti
dart run bin/dartisan.dart serve --watch  # restart otomatis saat file berubah
```

## Mencoba

Buka <http://127.0.0.1:8000> untuk halaman welcome dan
<http://127.0.0.1:8000/docs/api> untuk referensi API. User hasil seed
`test@example.com` login dengan `password`:

```bash
curl -s -X POST http://127.0.0.1:8000/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email": "test@example.com", "password": "password"}'
# {"user": {...}, "token": "1|...", "token_type": "Bearer"}

curl -s http://127.0.0.1:8000/api/users -H 'Authorization: Bearer 1|...'
```

## Menjalankan test

```bash
dart test                                 # di apps/daravel_starter
```

## Membangun binary native

```bash
dart build cli -t bin/server.dart -o build/server
build/server/bundle/bin/server            # .exe di Windows; butuh .env di sebelahnya
```

## Kalau ada masalah

| Gejala | Penyebab dan solusi |
| :-- | :-- |
| `pub get` menolak constraint SDK | Dart SDK lebih lama dari 3.13: perbarui, atau pakai `fvm dart` |
| `Address already in use` | Port 8000 dipakai program lain: ubah `APP_PORT` di `.env` |
| `APP_KEY is not set` | `.env` belum punya key: jalankan `key:generate` |
| Windows: `Cannot delete file ... sqlite3.dll` saat test | Server yang sedang jalan memegang library SQLite: hentikan dulu, lalu jalankan test |
| Anda ingin database bersih | Hapus `database/database.sqlite`, lalu jalankan `migrate --seed` lagi |

## Memakainya di luar repositori ini

Untuk memulai proyek sendiri, `dartisan new` adalah jalan yang lebih
singkat:

```bash
dart pub global activate dartisan_cli
dartisan new my_app
```

Kalau ingin menyalin folder ini: hapus baris `resolution: workspace` dari
`pubspec.yaml`, ganti setiap constraint `any` pada paket Daravel dengan
rilis terkini (misalnya `^1.24.0`), lalu jalankan `dart pub get` di folder
tersebut.
