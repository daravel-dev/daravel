<!-- source: migrating-from-laravel.md sha256:2fd9f1680c32 -->
# Migrasi dari Laravel, route demi route

Anda tidak harus menulis ulang aplikasi Laravel sekaligus. Karena Daravel
membaca dan menulis format Laravel (lihat [Koeksistensi dengan
Laravel](laravel-coexistence.md)), kedua aplikasi bisa melayani satu API
dari satu database sementara endpoint dipindahkan satu per satu. Inilah pola
*Strangler Fig*: reverse proxy mengirim endpoint yang sudah dipindahkan ke
Daravel dan sisanya ke Laravel, dan bagian Daravel terus tumbuh sampai
Laravel bisa dimatikan. Pola ini juga berlaku ke arah sebaliknya.

```
                 ┌──────────────── reverse proxy (Caddy / nginx) ───────────────┐
 client  ──TLS──▶│  /api/orders*, /api/reports*  ──▶ Daravel  (127.0.0.1:8000)  │
                 │  semua yang lain              ──▶ Laravel  (php-fpm)         │
                 └──────────────────────────────────────────────────────────────┘
                                 keduanya ──▶ satu database PostgreSQL
```

## Sebelum memulai

- **Server database yang sama.** Daravel berjalan di MySQL, MariaDB,
  PostgreSQL, dan SQLite, jadi bisa memakai database aplikasi Laravel apa
  adanya.
- **API dengan bearer token.** Personal access token Sanctum bekerja di
  kedua sisi. Cookie session dan CSRF dibagi lewat [daravel_session](sessions.md)
  (`APP_KEY` dan penyimpanan yang sama); mode SPA stateful dari Sanctum
  belum, jadi route yang bergantung padanya tetap di Laravel.
- Format **Laravel 10 sampai 13** langsung tersedia; [suite konformansi](laravel-coexistence.md)
  mengunci Laravel 13 dan Sanctum 4. Aplikasi Laravel 8 dan 9 men-set
  `COMPAT_LARAVEL_VERSION` (lihat akhir halaman ini).

## 1. Bagikan secret dan database

`dartisan adopt` mengerjakan langkah ini untuk Anda. Command ini membaca proyek
Laravel (dan tidak pernah mengubahnya), menyalin `APP_KEY`, cipher,
pengaturan `DB_*`, dan parameter hashing ke `.env` proyek ini, menetapkan
`CACHE_PREFIX` yang terpisah, lalu mengecek versi Laravel, driver database,
dan tabel-tabel bersama:

```bash
dart run bin/dartisan.dart adopt ../shop --check   # hanya laporan
dart run bin/dartisan.dart adopt ../shop           # menulis .env (backup: .env.before-adopt)
```

Bila dilakukan manual, pengaturannya:

```dotenv
# .env Daravel: database yang sama dan kunci yang sama dengan Laravel
APP_KEY=base64:...            # disalin dari .env Laravel
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_DATABASE=shop
DB_USERNAME=shop
DB_PASSWORD=...
AUTH_TOKEN_EXPIRATION=        # menit; samakan dengan config('sanctum.expiration')
CACHE_PREFIX=daravel_cache_   # pisahkan key cache (nilainya tidak portabel)
```

Cipher (`AES-256-CBC`) dan hasher password (bcrypt) sudah sama dengan
default Laravel. Set `APP_CIPHER` atau `HASH_DRIVER` hanya bila aplikasi
Laravel mengubahnya. `tokenable_type` milik token tetap `App\Models\User`,
jadi token yang diterbitkan Laravel bisa dipakai login di Daravel, begitu
juga sebaliknya.

## 2. Tentukan satu pemilik skema

Kedua framework mencatat migrasi di tabel `migrations` yang sama. Biarkan
satu sisi memiliki skema selama keduanya berjalan:

- **Laravel pemiliknya** (pilihan yang biasa di awal): tabel dan kolom baru
  ditulis sebagai migrasi Laravel, dan `dartisan migrate` tidak dijalankan
  terhadap database bersama. `bootstrap/migrations.dart` milik Daravel tetap
  membangun skema untuk test dan database lokalnya sendiri, jadi cerminkan
  tabel-tabel Laravel di sana. Nama migrasi hanya cocok di tempat Daravel
  memakai nama dari Laravel (`0001_01_01_000001_create_cache_table`,
  `..._create_jobs_table`); yang lain, seperti migrasi `users` atau migrasi
  Sanctum yang dipublikasikan `php artisan install:api` dengan timestamp
  baru, akan dianggap belum dijalankan dan gagal karena tabelnya sudah ada.
  Jangan pernah menjalankan `dartisan migrate:fresh` atau `migrate:reset` di
  sana: keduanya juga menghapus atau me-rollback tabel Laravel.
- **Daravel pemiliknya** (setelah sebagian besar kode pindah): pindahkan
  migrasi yang tersisa ke `bootstrap/migrations.dart` dengan nama yang sama
  dan berhenti menjalankan `php artisan migrate`.

## 3. Pindahkan satu endpoint

Mulailah dengan endpoint yang hanya membaca. Pertahankan URI, nama route,
dan bentuk responsnya:

```php
// Laravel: routes/api.php
Route::get('/orders/{order}', [OrderController::class, 'show'])
    ->middleware('auth:sanctum')->name('orders.show');
```

```dart
// Daravel: routes/api.dart
router
    .get('/orders/{order}', orders.show)
    .name('orders.show')
    .middleware(const ['auth'])
    .returns(OrderResource.schema, name: 'Order');
```

Body error (401, 403, 404, 422, 429), paginasi, dan JSON resource sama
dengan Laravel, jadi client tidak bisa membedakan sisi mana yang menjawab.
Untuk mengeceknya, bandingkan kedua dokumen OpenAPI
(`dartisan openapi:generate` dengan output Scribe atau Scramble) dan
jalankan request yang sama terhadap keduanya:

```bash
for host in laravel.internal daravel.internal; do
  curl -s -H "Authorization: Bearer $TOKEN" "http://$host/api/orders/42" | jq -S . > "$host.json"
done
diff laravel.internal.json daravel.internal.json
```

Di test Daravel, matcher dari `package:daravel_test/conformance.dart`
memeriksa bentuk Laravel secara langsung.

## 4. Arahkan di proxy

### Caddy

```caddyfile
api.example.com {
	# Endpoint yang sudah dilayani Daravel
	@daravel path /api/orders /api/orders/* /api/reports/*
	handle @daravel {
		reverse_proxy 127.0.0.1:8000
	}

	# Sisanya tetap di Laravel
	handle {
		root * /var/www/shop/public
		php_fastcgi unix//run/php/php8.3-fpm.sock
		file_server
	}
}
```

### nginx

```nginx
upstream daravel { server 127.0.0.1:8000; keepalive 32; }

server {
    listen 443 ssl http2;
    server_name api.example.com;
    root /var/www/shop/public;

    # Endpoint yang sudah dilayani Daravel
    location ~ ^/api/(orders|reports)(/|$) {
        proxy_pass http://daravel;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Sisanya tetap di Laravel
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
}
```

Percayai proxy di Daravel agar IP client (rate limit, log) dan scheme
diambil dari `X-Forwarded-*`:

```dart
TrustProxiesMiddleware(proxies: ['127.0.0.1/32'])
```

Arahkan berdasarkan segmen path yang persis, bukan string prefix:
`/api/orders*` juga akan menangkap `/api/orders-archive`. Kedua framework
punya route health `/up`; biarkan monitoring memanggil setiap aplikasi di
port-nya masing-masing.

Mengembalikan sebuah endpoint cukup dengan mengubah satu baris di proxy,
karena kedua aplikasi tetap bekerja dengan data yang sama.
### Atau Daravel di depan

Tanpa proxy sendiri, Daravel bisa berdiri di depan Laravel: request yang
punya route di Daravel dijawab Daravel; selebihnya, apa pun method-nya,
diteruskan ke Laravel.

```dart
Application.configure(basePath: basePath)
    .withUpstream(url: 'http://127.0.0.1:8080')   // atau UPSTREAM_URL di .env
    // ...
```

Route baru di Daravel mengambil alih method dan path itu pada deploy
berikutnya, tanpa konfigurasi proxy yang perlu diubah. `GET /api/orders` di
Daravel tidak membuat `POST /api/orders` menjadi 405: request itu tetap
diteruskan ke Laravel. Body di-stream ke dua arah (upload dan download tidak
ditahan di memori), redirect, cookie (setiap `Set-Cookie`), dan body yang
terkompresi diteruskan apa adanya, dan `X-Powered-By` dihapus. Laravel
menerima alamat klien di `X-Forwarded-For`, `-Proto`, `-Host`, dan `-Port`,
jadi percayai Daravel di middleware `TrustProxies` Laravel
(`$middleware->trustProxies(at: '127.0.0.1')`). Jika Laravel tidak
menjawab, klien menerima 502; jika terlalu lambat (`timeout:`, 60 detik),
504. WebSocket tidak diteruskan.

### Progres

`dartisan route:diff` membandingkan route Laravel dengan route Daravel:
mana yang sudah dijawab Daravel, mana yang masih diteruskan ke Laravel, dan
mana yang hanya ada di Daravel. Nama parameter tidak berpengaruh (`{order}`
cocok dengan `{id}`).

```bash
dart run bin/dartisan.dart route:diff --laravel=/var/www/shop     # menjalankan php artisan route:list --json
dart run bin/dartisan.dart route:diff --laravel-json=routes.json  # output yang sudah disimpan
dart run bin/dartisan.dart route:diff --laravel=/var/www/shop --json
dart run bin/dartisan.dart route:diff --laravel=/var/www/shop --by-prefix
```

## 5. Pekerjaan latar belakang

- **Queue.** Kedua sisi bisa memakai tabel `jobs`, tetapi masing-masing
  hanya menjalankan job miliknya. Worker Daravel melewati job Laravel tanpa
  menyentuhnya. Worker Laravel akan menggagalkan job Daravel, jadi beri
  Daravel nama queue sendiri (`Queue.dispatch(job).onQueue('daravel')`,
  `dartisan queue:work --queue=daravel`).
- **Scheduler.** Pindahkan task terjadwal dengan menghapusnya dari
  `routes/console.php` dan menambahkannya ke jadwal Daravel dalam deploy
  yang sama, agar tidak pernah berjalan dua kali.
- **Cache.** Laravel menyimpan nilai yang di-serialize PHP, Daravel
  menyimpan JSON. Pisahkan prefix-nya (langkah 1).

## 6. Selesai

Ketika proxy tidak lagi mengirim apa pun ke Laravel, jadikan Daravel
pemilik skema (langkah 2: beri migrasinya nama yang tercatat di Laravel,
atau insert baris yang sesuai), pindahkan scheduler dan queue worker, lalu
hapus blok `handle` / `location` untuk Laravel. Lihat
[Deployment](deployment.md) untuk menjalankan Daravel sendirian.

## Aplikasi Laravel 8 dan 9

Semua yang di atas berlaku; empat hal berbeda untuk aplikasi yang tidak
pernah di-upgrade ke Laravel 10 atau lebih baru, dipelajari dari port nyata
sebuah aplikasi Laravel 8.83 di MariaDB:

- **Body error.** Set `COMPAT_LARAVEL_VERSION=8` (atau `9`) agar pesan
  validasi, ringkasan 422, dan pesan 404/405 sama dengan yang sudah di-parse
  client aplikasi ([Koeksistensi dengan Laravel](laravel-coexistence.md#versi-laravel-yang-lebih-lama)).
- **Strict mode MySQL.** Laravel men-set `sql_mode` pada setiap koneksi;
  `'strict' => false` di `config/database.php` lama meloloskan insert tanpa
  semua nilai `NOT NULL`. Tirukan dengan `DB_STRICT=false` (atau
  `DB_SQL_MODES`), atau strict mode default MariaDB menolak baris yang
  diterima aplikasi Laravel ([Database](database.md)).
- **State yang disimpan di static.** PHP melupakan semuanya di antara
  request, sehingga sebuah port cenderung menyimpan apa yang Laravel taruh
  di `Cache::remember`, rate limiter, atau blacklist JWT ke field static.
  Setiap worker isolate punya salinan static sendiri, dan hilang setelah
  restart. Pakai penyimpanan bersama yang sama seperti yang dipakai Laravel:

  ```dart
  // Laravel: Cache::remember('config.is_sqd', 600, fn () => ...)
  final isSqd = await Cache.remember<bool>(
    'config.is_sqd',
    const Duration(minutes: 10),
    () => Setting.query().where('key', 'is_sqd').exists(),
  );
  // Laravel: RateLimiter::tooManyAttempts('places:'.$ip, 5)
  final limiter = App.make<RateLimiter>();
  // Laravel: JWTAuth::invalidate($token) -> blacklist di cache
  await Auth.jwtGuard().invalidate(token);
  ```

  Dengan `CACHE_STORE=database` (tabel `cache` Laravel) nilainya bertahan
  saat restart dan sampai ke scheduler, seperti cache file Laravel;
  `dartisan lint` melaporkan static yang mengumpulkan state
  (`no_mutable_static_in_app`).
- **Envelope respons terenkripsi.** Aplikasi yang membungkus JSON dengan
  `openssl_encrypt(..., 'aes-256-cbc')` berkunci statis tetap berjalan
  dengan mode AES-CBC dari `daravel_teobiefy` ([teobiefy](teobiefy.md));
  endpoint baru sebaiknya memakai protokol X25519-nya.

## Model aplikasi (daragic)

`dartisan daragic:export` menulis struktur aplikasi sebagai DAM (Daravel
Application Model), format netral bahasa yang dibaca generator `daragic` ke
dua arah:

```bash
dart run bin/dartisan.dart daragic:export                         # dam/dam.json + dam/daragic.lock
dart run bin/dartisan.dart daragic:export --only=routes,models --out=build/dam
```

Command ini mem-boot aplikasi (tanpa melayani request) dan mencatat route
(method, URI dalam bentuk Laravel, nama, action controller dari
`.action()`, middleware, pola `where`, rule validasi baik sebagai DSL maupun
terstruktur, respons yang didokumentasikan), model dari
`bootstrap/models.dart` (tabel, key, fillable, cast, hidden, relasi beserta
key-nya, sebagai kelas `App\Models\...`), migrasi beserta batch-nya, skema
database, jadwal, job, feature flag, terjemahan, middleware, dan key dari
`.env.example`. File-nya deterministik (terurut, tanpa timestamp), jadi dua
hasil export bisa di-diff dengan rapi, dan tidak memuat secret: key yang
tampak rahasia (`*_KEY`, `*_PASSWORD`, `*_TOKEN`, ...) tidak menyimpan nilai
default. `daragic.lock` meng-hash setiap section dan entitas untuk
penggabungan inkremental.

Isi method (controller, closure, job, scope) belum diekspor: itu butuh
extractor Dialect IR. Route yang didaftarkan tanpa `.action()` tampil
sebagai closure. `report.unsupported` di dalam file mencantumkan apa yang
tidak disertakan, jadi tidak ada yang dibuang diam-diam.
