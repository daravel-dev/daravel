<!-- source: README.md sha256:c14b3e1bdf11 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel/README.md) · Bahasa Indonesia

Framework backend untuk Dart yang terinspirasi Laravel dan berjalan native
secara AOT. Routing, middleware, validasi dengan rule dan pesan Laravel,
query builder dan ORM ala Eloquent, migrasi, token yang kompatibel dengan
Sanctum, JWT, gate, cache, queue, event, scheduler, API resource, storage,
dan logging terstruktur, dilayani oleh satu executable native yang bisa
diskalakan ke banyak isolate.

Laravel dan Daravel bisa berbagi database: JSON error dan paginasi, token
Sanctum, hash bcrypt, payload `Crypt`, dan tabel-tabel framework memakai
format Laravel, dikunci oleh suite konformansi.

## Mengapa Daravel?

1. **Satu bundle native.** `dartisan build` mengompilasi aplikasi
   ahead-of-time, dengan SQLite disertakan lewat build hook: tanpa SDK,
   PHP-FPM, atau Node.js di server. Server melayani request pertamanya
   sekitar 14 ms setelah dijalankan, dan worker isolate berbagi kode yang
   sudah dikompilasi (sekitar 11 MB saat idle dengan satu worker, 12 MB
   dengan empat, di runner CI Linux).
2. **Tanpa reflection, tanpa `build_runner`.** Generator menulis Dart biasa
   ke registry yang eksplisit, sehingga compiler melihat persis apa yang Anda
   baca.
3. **Semua core di satu port.** Supervisor menjalankan N worker isolate,
   menjalankan ulang yang crash, dan menuntaskan request saat `SIGTERM`;
   isolate coordinator menjaga lock, cache `process`, dan rate limit tetap
   benar di semua worker tanpa Redis.
4. **State request tetap di request-nya.** Request, job, dan command
   berjalan di scope `Zone`-nya sendiri; transaksi sadar zone, dengan
   savepoint dan dispatch after-commit.
5. **Berjalan berdampingan dengan Laravel** di database SQLite atau
   PostgreSQL yang sama (atau MySQL dan MariaDB dengan `daravel_mysql`),
   sehingga aplikasi bisa dipindahkan
   [endpoint demi endpoint](https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/migrating-from-laravel.md).
6. **Route yang mendokumentasikan dirinya sendiri.** `.validates(...)` dan
   `.returns(...)` menegakkan 403/422 sebelum handler dan menghasilkan
   OpenAPI 3.1.
7. **Pengaman bawaan.** Hashing di compute isolate, lint AST yang menolak
   interpolasi SQL dan reflection, serta suite keamanan dan konformansi.

| Laravel | Daravel |
| :-- | :-- |
| `Route::post('/posts', [PostController::class, 'store'])` dengan `StorePostRequest $request` | `router.post('/posts', posts.store).validates(const StorePostRequest())` |
| `$request->validated()` | `request.validated()` |
| `$request->integer('page', 1)` | `await request.integer('page', 1)` |
| `User::where('active', true)->paginate()` | `await User.query().where('active', true).paginate()` |
| `DB::transaction(fn () => ...)` | `await DB.transaction(() async => ...)` |

## Memulai

Cara tercepat adalah lewat CLI, yang membuat proyek lengkap:

```bash
dart pub global activate dartisan_cli
dartisan new blog
cd blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch
```

Atau tambahkan framework ke paket yang sudah ada:

```bash
dart pub add daravel
```

```dart
import 'package:daravel/daravel.dart';

Application createApp() => Application.configure(basePath: '.')
    .withRouting(
      apiPrefix: '/api',
      api: (router) {
        router.get('/ping', (_) => {'message': 'pong'});
        router.post('/users', (request) async {
          final data = await request.validate({
            'email': 'required|email|unique:users',
            'password': 'required|min:8|confirmed',
          });
          return Response.created(data.toMap());
        });
      },
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
```

Lihat [`example/main.dart`](example/main.dart) dan
[dokumentasinya](https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/index.md),
termasuk [tabel paritas Laravel ⇄ Daravel](https://github.com/daravel-dev/daravel/blob/main/docs/guide/parity.md).

## Paket terkait

- [`dartisan_cli`](https://pub.dev/packages/dartisan_cli): pembuatan proyek, server development dengan hot reload, generator, migrasi, build native.
- [`daravel_test`](https://pub.dev/packages/daravel_test): `TestClient`, assertion, helper database, fake, dan matcher konformansi Laravel.
- [`daravel_lints`](https://pub.dev/packages/daravel_lints): rule lint AST untuk aplikasi Daravel.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" dan
"Flutter" adalah merek dagang Google LLC. Daravel adalah proyek independen,
tidak berafiliasi dengan maupun didukung oleh keduanya.
