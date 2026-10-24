# Memulai

## Kebutuhan

- Dart SDK `^3.13` (sudah termasuk di Flutter 3.47 ke atas).
- Untuk SQLite tidak perlu apa-apa lagi: `package:sqlite3` mengunduh build
  SQLite yang hash-nya diverifikasi saat build dan menyertakannya bersama
  aplikasi. Untuk memakai library SQLite milik sistem operasi, tambahkan ke
  `pubspec.yaml`:

  ```yaml
  hooks:
    user_defines:
      sqlite3:
        source: system
  ```

## Membuat proyek

```bash
dart pub global activate --source path packages/dartisan_cli   # dari checkout Daravel
dartisan new blog                  # template api: auth, user, token, test
dartisan new tiny --template=minimal
cd blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch   # hot reload
```

Setiap proyek punya CLI sendiri, `bin/dartisan.dart`, yang mengenal aplikasi
Anda (`createApp()` di `bootstrap/app.dart`). `dart run bin/dartisan.dart
help` menampilkan semua perintah.

## Struktur proyek

| Path | Fungsi |
| :-- | :-- |
| `bootstrap/app.dart` | `createApp()`: routing, middleware, auth, rate limit, exception |
| `bootstrap/*.dart` | registry eksplisit: migrasi, seeder, job, policy, listener, command |
| `routes/api.dart`, `routes/web.dart`, `routes/console.dart` | route dan jadwal |
| `lib/app/http/controllers`, `requests`, `resources` | lapisan HTTP |
| `lib/app/models`, `jobs`, `events`, `listeners`, `policies` | domain |
| `database/migrations`, `seeders`, `factories` | skema dan data |
| `test/feature`, `test/unit`, `test/conformance` | test |

Daravel tidak memakai refleksi maupun code generation saat build. Apa yang
di Laravel ditemukan otomatis, di sini didaftarkan eksplisit di
`bootstrap/`. Generator `dartisan make:*` menambahkan entrinya untuk Anda,
dan `dartisan lint` melaporkan file yang belum terdaftar.

## Build dan menjalankan

```bash
dart run bin/dartisan.dart build           # dart build cli → build/server/bundle
APP_ISOLATES=4 ./build/server/bundle/bin/server
dart run bin/dartisan.dart build --docker  # Dockerfile multi-stage
```

Hasil build berupa direktori: `bin/server` ditambah `lib/` berisi SQLite.
Deploy seluruh direktorinya. Lihat [Deployment](../deployment.md).
