<!-- source: getting-started.md sha256:1bca27ecb908 -->
# Memulai

## Kebutuhan

- Dart SDK `^3.13` (sudah termasuk di Flutter 3.47 atau lebih baru).
- Tidak ada yang lain untuk SQLite: `package:sqlite3` mengunduh build SQLite
  yang hash-nya diverifikasi saat build dan menyertakannya bersama aplikasi
  Anda. Untuk memakai library sistem operasi, tambahkan ke `pubspec.yaml`:

  ```yaml
  hooks:
    user_defines:
      sqlite3:
        source: system
  ```

## Membuat proyek

```bash
dart pub global activate dartisan_cli     # dari pub.dev
dartisan new blog                  # template api: auth, user, token, test
dartisan new tiny --template=minimal
cd blog
dartisan migrate --seed
dartisan serve --watch   # hot reload
```

Setiap proyek punya CLI miliknya sendiri, `bin/dartisan.dart`, yang mengenal
aplikasi Anda (`createApp()` di `bootstrap/app.dart`). Di dalam proyek,
`dartisan` global menjalankan CLI itu, sehingga `dartisan` saja menampilkan
semua command, termasuk milik Anda, dan `dartisan migrate --help`
menampilkan opsi sebuah command. `dart run bin/dartisan.dart <command>`
sama saja, tanpa tool global.

## Struktur proyek

Tata letaknya mengikuti Laravel 12:

| Path | Kegunaan |
| :-- | :-- |
| `bootstrap/app.dart` | `createApp()`: routing, middleware, auth, rate limit, exception |
| `bootstrap/*.dart` | registry eksplisit: migrasi, seeder, job, policy, listener, command |
| `routes/api.dart`, `routes/web.dart`, `routes/console.dart` | route dan jadwal |
| `lib/app/http/controllers`, `requests`, `resources` | lapisan HTTP |
| `lib/app/models`, `jobs`, `events`, `listeners`, `policies` | domain |
| `database/migrations`, `seeders`, `factories` | skema dan data |
| `test/feature`, `test/unit`, `test/conformance` | test |

Daravel tidak memakai reflection maupun code generation saat build. Apa yang
ditemukan Laravel secara otomatis dicantumkan secara eksplisit di
`bootstrap/`; generator `dartisan make:*` menambahkan entrinya untuk Anda,
dan `dartisan lint` melaporkan file yang belum masuk ke registry.

## Generator

```bash
dartisan make:model Post --migration --factory
dartisan make:controller PostController --api --model=Post
dartisan make:request StorePostRequest
dartisan make:job PublishPost
```

Template-nya ada di `dartisan_cli`; `stub:publish` menyalinnya ke `stubs/`
agar bisa Anda ubah.

## Memeriksa aplikasi

```bash
dartisan db:show                      # tabel beserta jumlah kolom dan baris
dartisan db:table users --limit=5     # kolom, lalu baris-baris pertama
dartisan tinker "await User.query().where('active', true).count()"
```

`tinker` mengevaluasi satu ekspresi Dart di dalam aplikasi yang sudah di-boot
(model sudah di-import untuk Anda) dan mencetak hasilnya; model dan koleksi
dicetak sebagai JSON. Dart tidak punya `eval`, jadi setiap pemanggilan
mengompilasi program kecil dan mem-boot aplikasi lagi; sekali jalan, bukan
REPL.

## Build dan menjalankan

```bash
dartisan build           # dart build cli → build/server/bundle
APP_ISOLATES=4 ./build/server/bundle/bin/server
dartisan build --docker  # Dockerfile multi-stage
```

Bundle-nya berupa direktori: `bin/server` ditambah `lib/` berisi SQLite yang
disertakan. Deploy seluruh direktorinya. Lihat [Deployment](deployment.md).
