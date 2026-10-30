<!-- source: README.md sha256:64b7c9d4c0ba -->
| [`packages/daravel_session`](packages/daravel_session) | Session yang kompatibel dengan Laravel (file atau tabel `sessions`), cookie terenkripsi, dan proteksi CSRF |
<!-- source: README.md sha256:5b04c2e6d073 -->
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/svg/daravel-logo-horizontal-on-dark.svg">
    <img src="docs/brand/svg/daravel-logo-horizontal-on-light.svg" alt="Daravel" height="96">
  </picture>
</p>

<p align="center">
  <a href="README.md">English</a> · Bahasa Indonesia
</p>

<p align="center">
  <strong>Pengalaman developer Laravel, dikompilasi menjadi satu biner native.</strong><br>
  Framework backend untuk Dart yang terinspirasi Laravel dan berjalan native secara AOT.
</p>

<p align="center">
  <a href="https://daravel.dev"><img src="https://img.shields.io/badge/website-daravel.dev-0175C2" alt="Website"></a>
  <a href="https://github.com/daravel-dev/daravel/actions/workflows/ci.yml"><img src="https://github.com/daravel-dev/daravel/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%5E3.13-0175C2?logo=dart&logoColor=white" alt="Dart ^3.13"></a>
  <a href="https://dart.dev/tools/dart-build"><img src="https://img.shields.io/badge/AOT-native%20bundle-16A34A" alt="AOT native bundle"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://pub.dev/packages/daravel"><img src="https://img.shields.io/pub/v/daravel?include_prereleases&label=pub.dev" alt="pub.dev version"></a>
  <a href="https://pub.dev/publishers/framework.daravel.dev"><img src="https://img.shields.io/pub/publisher/daravel" alt="pub.dev publisher"></a>
  <a href="https://github.com/sponsors/daravel-dev"><img src="https://img.shields.io/badge/Sponsor-@daravel--dev-ea4aaa?logo=github-sponsors&logoColor=white" alt="Sponsor daravel-dev"></a>
</p>

<p align="center">
  <a href="https://daravel.dev">Website</a> ·
  <a href="#tentang-daravel">Tentang</a> ·
  <a href="#mengapa-daravel">Mengapa Daravel</a> ·
  <a href="#fitur">Fitur</a> ·
  <a href="#laravel--daravel-sekilas">Laravel ↔ Daravel</a> ·
  <a href="#mulai-cepat">Mulai cepat</a> ·
  <a href="#struktur-proyek">Struktur</a> ·
  <a href="#cli-dartisan">dartisan</a> ·
  <a href="https://daravel.dev/id/index.html">Dokumentasi</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="#proses-desain">Desain</a> ·
  <a href="#brand">Brand</a>
</p>

---

## Tentang Daravel

Daravel adalah framework backend untuk Dart yang mengikuti **filosofi Laravel 11/12**: sintaks yang
ekspresif dan elegan, fitur lengkap sejak awal, dan konvensi yang membuat pekerjaan umum terasa
ringan. Daravel mempertahankan apa yang membuat Laravel disukai dan menambahkan apa yang hanya bisa
diberikan Dart: satu executable native, tipe statis dari route sampai database, dan semua core CPU
di satu port.

> **Status.** Daravel stabil sejak `1.0.0`; rilis saat ini adalah
> `<!-- release -->1.19.1<!-- /release -->`, dipublikasikan di
> [pub.dev](https://pub.dev/packages/daravel) oleh publisher terverifikasi
> `framework.daravel.dev`. API Dart mengikuti SemVer di lini `1.x`; format yang berhadapan
> dengan Laravel dikunci oleh suite konformansi.

## Mengapa Daravel?

1. **Satu bundle native.** `dartisan build` mengompilasi aplikasi ahead-of-time menjadi kode
   mesin, dengan SQLite disertakan lewat build hook. Server tidak butuh Dart SDK, PHP-FPM, runtime
   Node.js, maupun source code. Server menjawab request pertamanya sekitar 14 ms setelah
   dijalankan, dan worker isolate berbagi kode yang sudah dikompilasi: sekitar 11 MB memori saat
   idle dengan satu worker, 12 MB dengan empat.
2. **Tanpa reflection, tanpa langkah code generation.** `dart:mirrors` tidak ada di biner AOT, dan
   Daravel juga tidak butuh `build_runner`. `dartisan make:*` dan `model:sync` menulis Dart biasa
   ke registry dan region accessor yang eksplisit, sehingga compiler melihat persis kode yang Anda
   baca.
3. **Semua core di satu port, sebelum Anda butuh Redis.** `serve --isolates=N` menjalankan
   supervisor yang menjalankan ulang worker yang crash, berhenti bila crash terus berulang, dan
   menuntaskan request yang sedang berjalan saat `SIGTERM`. Isolate coordinator menjaga atomic
   lock, cache `process`, dan rate limit fixed-window ala Laravel tetap benar di semua worker;
   lease lokal menjauhkan route yang di-throttle dari jalur panas coordinator.
4. **State request tetap di request-nya.** Setiap request, job, dan command berjalan di scope
   `Zone`-nya sendiri, dan facade (`Auth`, `DB`, `Cache`, `Log`) me-resolve dari scope itu.
   `DB.transaction` juga sadar zone: pemanggilan bersarang menjadi savepoint, job di queue dan
   event `dispatchAfterCommit` menunggu commit terluar dan dibuang saat rollback, dan di SQLite
   request lain menunggu transaksi yang terbuka alih-alih berjalan di dalamnya.
5. **Berjalan berdampingan dengan Laravel di database yang sama.** Hash bcrypt `$2y$`, payload
   `Crypt` (AES-256-CBC atau GCM, dengan rotasi `APP_PREVIOUS_KEYS`), personal access token
   Sanctum, JSON 422 dan paginator, resource, serta tabel `migrations`, `cache`, `jobs`, dan
   `failed_jobs` mengikuti Laravel 12, dan queue worker Daravel membiarkan job Laravel. Ini
   berlaku di SQLite, PostgreSQL, MySQL, dan MariaDB, dan dikunci oleh suite konformansi.
   Pindahkan aplikasi [endpoint demi endpoint](docs/guide/id/migrating-from-laravel.md).
6. **Route yang mendokumentasikan dirinya sendiri.** `.validates(StoreUserRequest())`,
   `.rules({...})`, dan `.returns(UserResource.schema, shape: .paginated)` membuat kernel
   menjawab 403/422 sebelum handler berjalan, mengisi `request.validated()`, dan menjadi masukan
   `dartisan openapi:generate`, yang mengubah rule Laravel yang sama (`required|email|max:255`,
   `items.*.id`, `confirmed`) menjadi OpenAPI 3.1.
7. **Pengaman bawaan.** Hashing password (bcrypt, Argon2id, PBKDF2) berjalan di compute isolate,
   sehingga lonjakan login tidak memblokir event loop. `dartisan lint` menolak interpolasi string
   SQL, `dart:mirrors`, `print`, dan static yang bisa diubah di kode aplikasi, serta kelas yang
   tertinggal dari registry. Suite regresi keamanan dan suite konformansi berjalan di CI.

Diukur, bukan diklaim: [`bench/`](bench/README.md) mem-build server secara AOT dan melaporkan
setiap skenario relatif terhadap server `dart:io` polos di run yang sama. Angka di atas berasal dari
workflow benchmark di runner Linux GitHub Actions dengan 4 CPU, tempat `GET /ping` Daravel
mencapai 55% throughput `dart:io` polos dengan satu isolate dan 78% dengan empat (generator beban
berbagi mesin yang sama).

## Fitur

| Area | Yang tersedia saat ini |
| :-- | :-- |
| **Fondasi** | Service container dengan masa hidup singleton/scoped/transient, deferred provider, `.env` + `.env.{APP_ENV}`, section konfigurasi bertipe, validasi konfigurasi saat boot |
| **HTTP** | Pipeline middleware dengan alias, grup, dan prioritas; trusted proxy, CORS, header keamanan, batas body, request id, timeout per route, `defer()`, terminable middleware |
| **Routing** | Router radix, batasan, parameter opsional, grup, resource, route model binding, route bernama, signed URL |
| **Validasi** | ~50 rule dengan semantik keberadaan ala Laravel, wildcard (`items.*.id`), `FormRequest`, payload 422 Laravel 12, pesan `en`/`id` |
| **Database** | Query builder untuk grammar SQLite, PostgreSQL, dan MySQL; paginasi length-aware, sederhana, dan cursor; savepoint; retry; callback after-commit |
| **ORM** | Hybrid Active Record: cast, accessor/mutator, scope, soft delete, observer, eager loading, `HasOne/HasMany/BelongsTo/BelongsToMany/HasManyThrough` |
| **Skema** | Membuat dan mengubah tabel, foreign key, rebuild tabel SQLite, `migrate:fresh`, seeder, model factory dengan faker bawaan |
| **Auth** | Hashing Argon2id/bcrypt/PBKDF2 di luar event loop, `Crypt` AES-256, token yang kompatibel dengan Sanctum, JWT (HS256/EdDSA), multi-guard `auth:token,jwt`, Gate & Policy, middleware `can:` |
| **Konkurensi** | Supervisor + worker yang berbagi satu port, readiness barrier, respawn dengan deteksi crash berulang, isolate coordinator untuk state seluruh proses |
| **Cache & limit** | Store memory (LRU), process, file, dan database; `remember` dengan perlindungan stampede, `flexible`, atomic lock; rate limiter fixed-window ala Laravel (dibagi semua worker, dengan lease lokal adaptif) dan `throttle:` |
| **Realtime** | Laravel Echo lewat protokol Pusher seperti Laravel Reverb (channel publik, private, dan presence, whisper), `ShouldBroadcast`, broadcast lewat Reverb atau Pusher Channels, route SSE dan WebSocket |
| **Queue & jadwal** | Event dengan listener di queue, job dengan retry, backoff, timeout, unique job, dan middleware; driver sync/memory/database; scheduler cron dengan perlindungan tumpang tindih |
| **API & file** | `JsonResource` dengan atribut kondisional dan koleksi `data/links/meta` ala Laravel; disk local/public/memory dengan `Storage.fake()` |
| **Observabilitas** | Logging terstruktur berbasis channel dengan konteks request dan redaksi secret, Prometheus `/metrics` yang digabung dari semua worker, health probe `/up` dan `/up/ready` |
| **Testing** | `TestClient` dengan `actingAs` dan 30+ assertion fluent, `refreshDatabase` (migrasi sekali, rollback di setiap test), assertion database, fake `Event/Queue/Storage`, `Log.spy()`, time travel lewat `Clock` |
| **Kualitas** | `daravel_lints` (tanpa reflection, tanpa `print`, tanpa static yang bisa diubah di `lib/app`, tanpa interpolasi SQL, kelas yang belum terdaftar) dan pengecekan arsitektur untuk aplikasi maupun graf modul framework itu sendiri |
| **Konformansi Laravel** | Format wire dan penyimpanan Laravel 12 yang dikunci (error, paginasi, resource, token Sanctum, bcrypt, `Crypt`, tabel bersama), `parity.yaml` yang dicek mesin, dan matcher konformansi untuk test Anda sendiri |
| **Keamanan & performa** | Suite regresi keamanan (injection, spoofing, JWT, traversal, ReDoS, fuzzing, timing) dan harness benchmark dengan gerbang regresi setiap malam |

## Laravel ↔ Daravel sekilas

Daravel mempertahankan nama dan semantik Laravel dan hanya menyesuaikan sintaksnya dengan Dart.

<table>
<tr>
<th width="50%">Laravel (PHP)</th>
<th width="50%">Daravel (Dart)</th>
</tr>
<tr>
<td>

```php
// bootstrap/app.php
return Application::configure(basePath: __DIR__)
    ->withRouting(api: __DIR__.'/../routes/api.php', health: '/up')
    ->withMiddleware(fn (Middleware $m) => $m->append(RequestId::class))
    ->withSchedule(fn (Schedule $s) => $s->job(new PruneTokens)->daily())
    ->create();
```

</td>
<td>

```dart
// bootstrap/app.dart
Application createApp() => Application.configure(basePath: '.')
    .withRouting(api: apiRoutes, health: '/up')
    .withMiddleware((m) => m.use(const [RequestIdMiddleware()]))
    .withSchedule((s) => s.job(const PruneTokens()).daily())
    .create();
```

</td>
</tr>
<tr>
<td>

```php
// routes/api.php
Route::post('/auth/login', [AuthController::class, 'login'])
    ->middleware('throttle:login');
Route::middleware('auth:sanctum')->group(function () {
    Route::get('/auth/me', [AuthController::class, 'me']);
    Route::patch('/users/{user}', [UserController::class, 'update'])
        ->can('update', 'user');
});
```

</td>
<td>

```dart
// routes/api.dart
router.post('/auth/login', auth.login)
    .middleware(const ['throttle:login']);
router.group(middleware: const ['auth'], (r) {
  r.get('/auth/me', auth.me);
  r.patch('/users/{user}', users.update)
      .middleware(const ['can:update,user']);
});
```

</td>
</tr>
<tr>
<td>

```php
public function store(Request $request)
{
    $data = $request->validate([
        'email'    => 'required|email|unique:users',
        'password' => 'required|min:8|confirmed',
    ]);

    $user = DB::transaction(fn () => User::create([
        ...$data, 'password' => Hash::make($data['password']),
    ]));
    UserRegistered::dispatch($user);

    return new UserResource($user);       // 201: baru dibuat
}
```

</td>
<td>

```dart
Future<Object?> store(Request request) async {
  final data = await request.validate({
    'email':    'required|email|unique:users',
    'password': [Rules.required(), Rules.min(8), Rules.confirmed()],
  });

  final user = await DB.transaction(() async => User.create({
    'email': data.string('email'),
    'password': await Hash.make(data.string('password')),
  }));
  await Event.dispatch(UserRegistered(user.id, user.email));

  return UserResource(user);             // 201: baru dibuat
}
```

</td>
</tr>
<tr>
<td>

```php
// FormRequest diinjeksi dan berjalan lebih dulu.
Route::post('/posts', [PostController::class, 'store']);

public function store(StorePostRequest $request)
{
    return Post::create($request->validated());
}

public function index(Request $request)
{
    $page = $request->integer('page', 1);
    $tags = $request->query('tags', []);  // ?tags[]=a&tags[]=b
}
```

</td>
<td>

```dart
// Dideklarasikan di route: 403/422 lebih dulu, dan tercatat di OpenAPI.
router.post('/posts', posts.store)
    .validates(const StorePostRequest())
    .returns(PostResource.schema, name: 'Post');

Future<Object?> store(Request request) async =>
    PostResource(await Post.create(request.validated().toMap()));

Future<Object?> index(Request request) async {
  final page = await request.integer('page', 1);
  final tags = request.queryInput['tags'];  // ['a', 'b']
}
```

</td>
</tr>
<tr>
<td>

```php
class SendWelcomeEmail implements ShouldQueue
{
    public $tries = 3;
    public $backoff = [10, 60];

    public function handle(): void { /* … */ }
}

SendWelcomeEmail::dispatch($user)->onQueue('emails');
```

</td>
<td>

```dart
final class SendWelcomeEmail extends Job {
  @override int get tries => 3;
  @override List<Duration> get backoff =>
      const [Duration(seconds: 10), Duration(seconds: 60)];

  @override Future<void> handle(JobContext ctx) async { /* … */ }
}

await Queue.dispatch(SendWelcomeEmail(user.id)).onQueue('emails');
```

</td>
</tr>
<tr>
<td>

```php
$value = Cache::remember('stats', 600, fn () => Stats::compute());

Cache::lock('report')->block(5, function () {
    // eksklusif di semua worker
});
```

</td>
<td>

```dart
final value = await Cache.remember('stats',
    const Duration(minutes: 10), Stats.compute);

await Cache.lock('report').block(const Duration(seconds: 5), () async {
  // eksklusif di semua worker
});
```

</td>
</tr>
<tr>
<td>

```php
$this->postJson('/api/auth/register', $payload)
     ->assertCreated()
     ->assertJsonPath('user.email', 'ana@example.com');

Queue::assertPushed(SendWelcomeEmail::class);
```

</td>
<td>

```dart
(await client.post('/api/auth/register', json: payload))
    .assertCreated()
    .assertJsonPath('user.email', 'ana@example.com');

fake.assertPushed<SendWelcomeEmail>();
```

</td>
</tr>
</table>

## Mulai cepat

Membutuhkan [Dart SDK](https://dart.dev/get-dart) `^3.13` (Flutter 3.47+). SQLite sistem tidak
diperlukan: `package:sqlite3` mengunduh build SQLite yang hash-nya diverifikasi lewat build hook
dan menyertakannya bersama aplikasi (set `hooks: user_defines: sqlite3: source: system` di
`pubspec.yaml` untuk memakai library sistem operasi).

Buat aplikasi dengan CLI dari pub.dev:

```bash
dart pub global activate dartisan_cli
dartisan new blog                             # template api; --template=minimal untuk yang lebih ringkas
cd blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch
```

Atau kerjakan framework-nya sendiri dan jalankan aplikasi starter dari clone:

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                                  # me-resolve seluruh workspace

cd apps/daravel_starter
cp .env.example .env
dart run bin/dartisan.dart key:generate       # menulis APP_KEY ke .env
dart run bin/dartisan.dart migrate --seed     # tabel users, tokens, cache, dan jobs
dart run bin/dartisan.dart serve --watch      # http://127.0.0.1:8000 dengan hot reload
```

```bash
curl http://127.0.0.1:8000/up                 # liveness
curl http://127.0.0.1:8000/up/ready           # {"status":"ok","checks":{"database":…,"cache":…}}
curl -X POST http://127.0.0.1:8000/api/auth/register \
     -H 'content-type: application/json' \
     -d '{"name":"Ana","email":"ana@example.com","password":"secret-123","password_confirmation":"secret-123"}'
```

Atau mulai aplikasi baru dari clone (`--path` menunjuk ke checkout framework; `--source=git`
bergantung pada repository ini lewat git; default-nya memakai pub.dev):

```bash
dart run packages/dartisan_cli/bin/dartisan.dart new ../blog --path=.
cd ../blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch
```

Layani di semua core dan proses pekerjaan latar belakang:

```bash
dart run bin/dartisan.dart serve --isolates=4           # supervisor + 4 worker di satu port
dart run bin/dartisan.dart queue:work --queue=emails,default
dart run bin/dartisan.dart schedule:work
```

Kirim sebagai bundle native (`bin/server` ditambah SQLite yang disertakan di `lib/`; deploy
direktorinya):

```bash
dart run bin/dartisan.dart build                   # = dart build cli -t bin/server.dart -o build/server
APP_ISOLATES=4 METRICS_ENABLED=true ./build/server/bundle/bin/server
dart run tool/smoke.dart                           # mem-boot bundle dan mengujinya
dart run bin/dartisan.dart build --docker          # Dockerfile multi-stage, tanpa libsqlite3
```

## Struktur proyek

Aplikasi starter mengikuti tata letak Laravel 12, jadi developer Laravel tidak akan tersesat:

```text
apps/daravel_starter/
├── bin/
│   ├── server.dart              # entrypoint HTTP (dikompilasi menjadi biner native)
│   └── dartisan.dart            # CLI milik proyek
├── bootstrap/
│   ├── app.dart                 # Application.configure(...): routing, auth, event, jadwal
│   ├── migrations.dart          # registry eksplisit yang dirawat `dartisan make:*`
│   ├── seeders.dart
│   ├── jobs.dart
│   ├── policies.dart            # registerPolicies(gate)
│   ├── listeners.dart           # registerListeners(events)
│   └── commands.dart            # command dartisan buatan sendiri
├── routes/
│   ├── api.dart                 # di-mount di bawah /api
│   ├── web.dart
│   └── console.dart             # task terjadwal
├── lib/app/
│   ├── console/commands/        # command dartisan buatan sendiri
│   ├── events/                  # kelas event biasa
│   ├── http/controllers/        # controller adalah kelas biasa; handler berupa tear-off method
│   ├── http/requests/           # FormRequest
│   ├── http/resources/          # JsonResource
│   ├── jobs/                    # job di queue
│   ├── listeners/               # listener event
│   ├── models/                  # model Hybrid Active Record
│   └── policies/                # policy otorisasi
├── database/
│   ├── migrations/              # m_<timestamp>_<name>.dart
│   ├── factories/
│   └── seeders/
├── test/
│   ├── feature/                 # test TestClient dan refreshDatabase (SQLite in-memory)
│   └── architecture_test.dart   # lint, kelengkapan registry, aturan import
└── tool/smoke.dart              # smoke test biner AOT yang dipakai CI
```

Monorepo ini adalah pub workspace Dart:

| Paket | Kegunaan |
| :-- | :-- |
| [`packages/daravel`](packages/daravel) | Inti framework |
| [`packages/daravel_test`](packages/daravel_test) | Toolkit testing: `TestClient`, assertion, `refreshDatabase`, time travel, helper arsitektur |
| [`packages/daravel_lints`](packages/daravel_lints) | Rule lint berbasis AST dan pengecekan registry, dijalankan oleh `dartisan lint` dan di test |
| [`packages/dartisan_cli`](packages/dartisan_cli) | Command-line interface `dartisan` dan generator kode |
| [`packages/daravel_mysql`](packages/daravel_mysql) | Driver MySQL dan MariaDB |
| [`packages/daravel_permission`](packages/daravel_permission) | Role dan permission pada tabel spatie/laravel-permission |
| [`packages/daravel_activitylog`](packages/daravel_activitylog) | Riwayat perubahan model dan activity log pada tabel spatie/laravel-activitylog |
| [`packages/daravel_excel`](packages/daravel_excel) | Ekspor dan impor Excel dan CSV dengan concern Laravel Excel, di-stream dengan memori konstan |
| [`packages/daravel_log_viewer`](packages/daravel_log_viewer) | Halaman log viewer: file dibaca dari ujungnya, filter, live tail, data rahasia disensor |
| [`packages/daravel_pulse`](packages/daravel_pulse) | Dashboard seperti Laravel Pulse: request, request dan query lambat, exception, queue, dari semua isolate |
| [`packages/daravel_payments`](packages/daravel_payments) | Midtrans, Xendit, dan Stripe di balik satu API; webhook diverifikasi, diterapkan sekali, jumlah dicek |
| [`packages/daravel_medialibrary`](packages/daravel_medialibrary) | File dan gambar yang dilekatkan ke model di tabel media spatie/laravel-medialibrary, konversi murni Dart |
| [`packages/daravel_teorion`](packages/daravel_teorion) | Query filter dari request, format laravel-teorion |
| [`packages/daravel_livekit`](packages/daravel_livekit) | SDK server LiveKit: access token, room, webhook terverifikasi |
| [`packages/daravel_google`](packages/daravel_google) | Google: token OAuth dengan refresh, service account, event Calendar dengan link Meet |
| [`packages/daravel_teobiefy`](packages/daravel_teobiefy) | Payload API terenkripsi yang kompatibel dengan protokol teobiefy v1 di Laravel |
| [`packages/daravel_s3`](packages/daravel_s3) | Disk penyimpanan S3, Cloudflare R2, dan MinIO: SigV4 Dart murni, streaming multipart, presigned URL |
| [`packages/daravel_redis`](packages/daravel_redis) | Redis dan Valkey untuk beberapa server: cache, lock, rate limit, queue, broadcasting |
| [`packages/daravel_sqlite`](packages/daravel_sqlite) | Paket driver SQLite (`db:install sqlite`) |
| [`packages/daravel_postgres`](packages/daravel_postgres) | Paket driver PostgreSQL (`db:install pgsql`) |
| [`apps/daravel_starter`](apps/daravel_starter) | Aplikasi referensi dan test end-to-end |
| [`apps/virtual_classroom`](apps/virtual_classroom) | Aplikasi contoh: jadwal pelajaran di room LiveKit, undangan Google Calendar, role, query filter, activity log |

Kedelapan belas paket ([`daravel`](https://pub.dev/packages/daravel),
[`dartisan_cli`](https://pub.dev/packages/dartisan_cli),
[`daravel_test`](https://pub.dev/packages/daravel_test),
[`daravel_lints`](https://pub.dev/packages/daravel_lints),
[`daravel_mysql`](https://pub.dev/packages/daravel_mysql),
[`daravel_permission`](https://pub.dev/packages/daravel_permission),
[`daravel_session`](https://pub.dev/packages/daravel_session),
[`daravel_activitylog`](https://pub.dev/packages/daravel_activitylog),
[`daravel_excel`](https://pub.dev/packages/daravel_excel),
[`daravel_log_viewer`](https://pub.dev/packages/daravel_log_viewer),
[`daravel_pulse`](https://pub.dev/packages/daravel_pulse),
[`daravel_payments`](https://pub.dev/packages/daravel_payments),
[`daravel_medialibrary`](https://pub.dev/packages/daravel_medialibrary),
[`daravel_redis`](https://pub.dev/packages/daravel_redis),
[`daravel_teorion`](https://pub.dev/packages/daravel_teorion),
[`daravel_livekit`](https://pub.dev/packages/daravel_livekit),
[`daravel_google`](https://pub.dev/packages/daravel_google),
[`daravel_teobiefy`](https://pub.dev/packages/daravel_teobiefy),
[`daravel_s3`](https://pub.dev/packages/daravel_s3),
[`daravel_sqlite`](https://pub.dev/packages/daravel_sqlite),
[`daravel_postgres`](https://pub.dev/packages/daravel_postgres)) dirilis bersama dengan satu
versi oleh publisher terverifikasi
[`framework.daravel.dev`](https://pub.dev/publishers/framework.daravel.dev); hanya paket
dari publisher itu yang merupakan bagian dari proyek ini. pub.dev juga menandainya kompatibel
dengan Flutter karena paketnya Dart murni, tetapi Daravel adalah framework server untuk Linux,
macOS, dan Windows.

## CLI dartisan

| Kelompok | Command |
| :-- | :-- |
| Proyek | `new <name> [--template=api\|minimal] [--path] [--git]`, `about`, `doctor [--production]`, `key:generate [--show] [--force]`, `stub:publish`, `env:encrypt`, `env:decrypt`, `env:obfuscate`, `adopt <laravel-path> [--check]`, `down [--secret] [--retry]`, `up`, `tinker "<expr>"` |
| Serve & build | `serve [--host] [--port] [--isolates] [--watch] [--embed-queue] [--embed-scheduler]`, `build [--output] [--with-cli] [--docker] [--no-sqlite]`, `test [--conformance] [--security] [--coverage]`, `route:list [--path] [--method] [--name] [--json]`, `openapi:generate`, `lint [--json]`, `mcp:serve [--allow-write]`, `mcp:install`, `coordinator:stats` |
| Database | `migrate [--seed]`, `migrate:status`, `migrate:rollback [--step]`, `migrate:reset`, `migrate:fresh [--seed] [--force]`, `db:seed [--class] [--all]`, `model:sync [Model] [--dry-run]`, `model:show <Model> [--json]`, `db:show`, `db:table <table> [--limit]` |
| Generator | `make:model [-m -f -s -c -p -r --api --all]`, `make:migration`, `make:seeder`, `make:factory`, `make:controller [--api --resource --model]`, `make:request`, `make:middleware`, `make:job`, `make:policy`, `make:event`, `make:listener [--event]`, `make:resource`, `make:rule`, `make:observer`, `make:provider`, `make:command`, `make:test [--unit]` |
| Queue | `queue:work [--queue --tries --backoff --timeout --max-jobs --once]`, `queue:failed`, `queue:retry`, `queue:forget`, `queue:flush`, `queue:clear`, `queue:restart` |
| Jadwal | `schedule:run`, `schedule:work`, `schedule:list` |
| Cache & file | `cache:clear [store]`, `storage:link` |

Generator memperbarui registry di `bootstrap/` (migrasi, seeder, job, policy, listener, dan
command buatan sendiri) melalui region yang ditandai, sehingga kelas baru langsung terhubung saat
dibuat. Setiap template bisa diubah setelah `stub:publish`:

```bash
dart run bin/dartisan.dart make:model Post --all --api
```

```text
created lib/app/models/post.dart
created database/migrations/m_2026_10_24_090507_create_posts_table.dart
updated bootstrap/migrations.dart
created database/factories/post_factory.dart
created database/seeders/post_seeder.dart
updated bootstrap/seeders.dart
created lib/app/http/controllers/post_controller.dart
created lib/app/policies/post_policy.dart
updated bootstrap/policies.dart
created lib/app/http/resources/post_resource.dart
```

## Arsitektur singkat

- **Container + scope Zone.** `Container.runScoped('request', …)` menyimpan scope di `Zone`
  anak; facade me-resolve container milik zone lebih dulu dan jatuh ke root per isolate, sehingga
  `DB`, `Auth`, `Cache`, dan `Log` bekerja sama baiknya di request, job, command, dan test.
- **Siklus hidup request.** Middleware global → routing radix-tree → route model binding →
  middleware route → handler → konversi respons otomatis, lalu fase terminate setelah respons
  ditulis. `404`, `405` (dengan `Allow`), `HEAD`, dan `OPTIONS` berperilaku persis seperti Laravel.
- **Scope state (ADR-003).** Setiap store mendeklarasikan scope `isolate`, `process`, atau
  `cluster`. Rate limit dan lock default-nya `process` dan dilayani isolate coordinator, sehingga
  `throttle:60,1` berarti 60 per menit untuk seluruh server, bukan 60 per worker.
- **Transaksi yang sadar zone.** `DB.transaction(() async { … })` menaruh executor transaksi di
  zone. Job di queue dan event `dispatchAfterCommit` menunggu commit dan dibuang saat rollback,
  termasuk savepoint bersarang.
- **Aman secara default.** Hanya SQL berparameter, hashing di compute isolate, perbandingan secret
  dengan waktu konstan, verifikasi hash yang tahan downgrade, redaksi log, dan IP client yang
  memperhitungkan trusted proxy.

## Roadmap

| Tier | Cakupan | Status |
| :-- | :-- | :-- |
| **0** | Kerangka berjalan: container, kernel HTTP, router, SQLite, migrasi, test client, CLI, CI | ✅ selesai |
| **1** | S1 fondasi · S2 pengerasan HTTP · S3 routing · S4 validasi · S5 database · S6 ORM · S7 skema, seeding & generator · S8 auth · S9 multi-isolate & cache · S10 event, queue & scheduler · S11 resource, storage & observabilitas · S12 CLI (`new`, hot reload, `build --docker`, `doctor`, `openapi:generate`, `model:sync`, stub) · S13 toolkit testing, lint & test arsitektur | ✅ selesai |
| **1** | S14 suite konformansi, suite keamanan, `parity.yaml`, harness benchmark, situs dokumentasi, template `api`/`minimal` → beta publik pertama, lalu **1.0.0** | ✅ selesai |
| **1.x** | Dirilis setelah 1.0: lokalisasi, feature flag, SSE dan WebSocket, generator client Flutter, paket driver dan `db:transfer`, mail dan notifikasi, broadcasting untuk Laravel Echo, Redis dan Valkey (`daravel_redis`), role dan permission (`daravel_permission`), activity log (`daravel_activitylog`), query filter (`daravel_teorion`); terbaru **<!-- release -->1.19.1<!-- /release -->** | ✅ selesai |
| **2** | Session/CSRF, S3, OpenTelemetry, view terkompilasi yang kompatibel dengan Blade; client database hanya di paket driver | direncanakan |
| **daragic** | Generator dua arah Laravel ⇄ Daravel: introspeksi runtime → IR → proyek hasil generate, test yang dikonversi, differential replay | sudah didesain |
| **Ekosistem** | Paket first-party di bawah `daravel-dev`: `daravel_horizon` (supervisor dan dashboard queue), `daravel_socialite` (OAuth dan Sign in with Apple/Google), lalu `daravel_telescope` dan `daravel_scout` | direncanakan |

## Dokumentasi

Panduan ada di [`docs/guide/id`](docs/guide/id/index.md) dalam Bahasa Indonesia, dan di
[`docs/guide`](docs/guide/index.md) dalam bahasa Inggris: memulai, routing, validasi, database,
respons, auth, pekerjaan latar belakang, mail dan notifikasi, testing, deployment (Docker, Cloud
Run, VPS), koeksistensi dengan Laravel, [migrasi dari Laravel](docs/guide/id/migrating-from-laravel.md),
keamanan, performa, dan [tabel paritas Laravel ⇄ Daravel](docs/guide/parity.md) yang dihasilkan
otomatis. `dart run tool/docs/generate.dart` mem-build situs HTML ke `build/site`. Catatan rilis
ada di [CHANGELOG.md](CHANGELOG.md).

## Proses desain

Desain didokumentasikan sebelum dibangun. Arsitektur, spesifikasi modul, generator
Laravel ⇄ Daravel (`daragic`), dan rencana per slice ada di blueprint maintainer, dengan keputusan
dicatat sebagai ADR yang mengikat. Komentar kode merujuknya sebagai `BLUEPRINT_V2 §…` dan
`ADR-…`. Keputusan yang paling diandalkan runtime (state scope, supervisor beserta worker-nya, dan
default untuk koeksistensi dengan Laravel) dituliskan di [`docs/adr`](docs/adr/README.md).

## Brand

<img src="docs/brand/svg/daravel-icon.svg" alt="Daravel icon" width="72" align="right">

Logo Daravel adalah simpul tak hingga: lengkung biru untuk Dart dan lengkung merah untuk
warisan Laravel, untuk aplikasi yang berjalan di keduanya berdampingan dan bisa bermigrasi ke
dua arah, dibingkai ornamen emas. Ikon dari 16 sampai 1024 px, logo transparan, versi satu
warna, lockup terang dan gelap, social preview, dan `favicon.ico` ada di
[`docs/brand`](docs/brand), bersama aturan pemakaiannya. Setiap file dihasilkan oleh
`tool/brand/generate.dart` (`dart run tool/brand/generate.dart`) dari ilustrasi di
`docs/brand/source`, yang menjadi sumber kebenaran.

## Gerbang kualitas

Setiap commit dijalankan di Linux, Windows, dan macOS: `dart format --set-exit-if-changed`,
`dart analyze --fatal-infos` dengan strict casts, inference, dan raw types, `dart test` untuk
setiap paket (termasuk suite konformansi Laravel, suite keamanan, dan pengecekan `parity.yaml`),
pengecekan kemutakhiran dokumentasi dan terjemahannya, `dart build cli` untuk starter, dan smoke
test terhadap biner yang dihasilkan. Benchmark dijalankan setiap malam (`bench/`).

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
(cd packages/daravel && dart test)
(cd packages/daravel_lints && dart test)
(cd packages/daravel_test && dart test)
(cd packages/dartisan_cli && dart test)
(cd apps/daravel_starter && dart test)
(cd packages/daravel && dart test --tags conformance)   # hanya kontrak Laravel
(cd packages/daravel && dart test --tags security)      # hanya suite keamanan
dart run tool/docs/generate.dart --check
```

## Mendukung & Mensponsori Daravel

Dukung pengembangan berkelanjutan Daravel melalui GitHub Sponsors:

- [💖 Sponsor @daravel-dev](https://github.com/sponsors/daravel-dev)

## Berkontribusi

Daravel terbuka untuk diskusi desain sama halnya dengan kode. Buka issue untuk mengusulkan
perubahan desain, atau pull request yang menjaga semua gerbang kualitas tetap hijau. Commit
memakai sign-off DCO. Lihat [CONTRIBUTING.md](CONTRIBUTING.md).

## Kerentanan keamanan

Bila Anda menemukan kerentanan keamanan, laporkan secara privat seperti dijelaskan di
[SECURITY.md](SECURITY.md), bukan dengan membuka issue publik.

## Lisensi & merek dagang

Daravel adalah perangkat lunak open-source berlisensi [MIT](LICENSE). Kode yang dihasilkan
`dartisan` (`new`, `make:*`, `model:sync`) atau `daragic` di proyek Anda sepenuhnya milik Anda,
tanpa batasan lisensi tambahan.
Teks dan logika yang mengikuti Laravel dan Spatie, beserta lisensi MIT
keduanya, dicantumkan di [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

**Penafian merek dagang:** "Laravel" adalah merek dagang Laravel Holdings Inc. "Dart" dan
"Flutter" adalah merek dagang Google LLC. Daravel adalah proyek open-source independen dan tidak
berafiliasi dengan, didukung oleh, atau disponsori oleh Laravel Holdings Inc. maupun Google LLC.
Laravel disebut hanya untuk menjelaskan inspirasi desain dan interoperabilitas (nominative fair
use).
