<!-- source: database.md sha256:e409b7119dc6 -->
# Database

`DB_CONNECTION` memilih SQLite (`sqlite`, default), PostgreSQL (`pgsql`),
MySQL (`mysql`), atau MariaDB (`mariadb`). MySQL dan MariaDB berasal dari
`package:daravel_mysql`, yang didaftarkan proyek baru di
`bootstrap/app.dart`:

```dart
Application.configure(basePath: '.')
    .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
    .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
```

SQLite dan PostgreSQL sudah tertanam di Daravel 1.x. Lihat [Driver dan
koneksi](#driver-dan-koneksi) untuk paket driver dan untuk memakai beberapa
database sekaligus.

Di MySQL, hasil query terbaca seperti di Laravel (`TINYINT(1)` sebagai
`0`/`1`, `DECIMAL` dan `JSON` sebagai string, tanggal sebagai
`Y-m-d H:i:s`), dan zona waktu session mengikuti server kecuali
`DB_TIMEZONE` di-set, sehingga kolom `TIMESTAMP` terbaca sama dari kedua
framework. MySQL 8.4 dan MariaDB 11 dijalankan di CI pada setiap commit.
Setiap query dibangun oleh grammar dengan nilai terikat (parameter binding);
identifier selalu dikutip.

Laravel mengatur `sql_mode` pada setiap koneksi MySQL berdasarkan key
`'strict'` koneksinya (`true` di `config/database.php` bawaannya). Daravel
membiarkan mode dari server kecuali diatur: `DB_STRICT=true` memasang mode
strict yang dipasang Laravel, `DB_STRICT=false` memasang
`NO_ENGINE_SUBSTITUTION` seperti Laravel dengan `'strict' => false`
(`INSERT` tanpa nilai untuk kolom `NOT NULL` lalu menyimpan `''` atau `0`
alih-alih gagal), dan `DB_SQL_MODES` memasang daftar mode yang eksplisit.
Samakan dengan aplikasi Laravel yang memakai database yang sama.
`DB_ISOLATION_LEVEL` mengatur isolation level transaksi, dan
`MySqlDriver(initCommands: [...], onConnectionOpen: ...)` menjalankan
perintah lain pada setiap koneksi baru.

## Driver dan koneksi

Setiap client database adalah sebuah paket. MySQL dan MariaDB sudah bekerja
dengan cara ini. Untuk SQLite (`daravel_sqlite`) dan PostgreSQL
(`daravel_postgres`), paketnya meng-export ulang driver yang masih tertanam
di 1.x, jadi menambahkannya tidak mengubah apa pun saat ini. Di 2.0,
`package:daravel` berhenti bergantung pada client database mana pun, dan
driver hanya ada di paket-paket ini. Proyek yang sudah bergantung pada paket
driver-nya lalu bisa upgrade tanpa perubahan, dan tidak lagi mem-build atau
menyertakan client yang tidak dipakainya.

`dartisan db:install` menambahkan paket driver, mendaftarkannya, dan
mendokumentasikan pengaturannya:

```bash
dart run bin/dartisan.dart db:install pgsql     # atau sqlite, mysql, mariadb
```

| Yang diubah | Dengan |
| :-- | :-- |
| `pubspec.yaml` | `daravel_postgres: ^<version>` (lalu `dart pub get`; `--no-get` melewatinya) |
| `bootstrap/app.dart` | import dan `.withPostgres()` (`.withSqlite()`, atau baris `withDatabaseDriver` untuk MySQL) setelah `Application.configure(...)` |
| `.env.example` | blok berkomentar dengan key `DB_*` dari driver; untuk PostgreSQL juga `DB_POOL_SIZE=10` dan `HTTP_MAX_IN_FLIGHT=40` ([load shedding](deployment.md#load-shedding) yang disesuaikan dengan pool) |

Menjalankannya lagi tidak mengubah apa pun.

### SQLite atau PostgreSQL

SQLite untuk development, test, dan deployment dengan satu isolate.
PostgreSQL (atau MySQL dan MariaDB) untuk production dengan `APP_ISOLATES`
lebih dari 1.

SQLite tetap bekerja dengan beberapa isolate: setiap isolate membuka file
yang sama dalam mode WAL dan menunggu sampai 5 detik (`busy_timeout`) untuk
write lock dari isolate lain. Namun pemanggilan SQLite bersifat sinkron,
sehingga selama sebuah worker menunggu lock itu, seluruh event loop-nya ikut
menunggu, begitu pula setiap request di worker tersebut. Penulisan
diserialkan di seluruh server. `serve` mencatat warning saat menjalankan
beberapa isolate di atas file SQLite, dan `dartisan doctor` memberi
catatan; lihat [Operasional](operations.md) untuk menghitung koneksi
PostgreSQL.

### Mengganti database default

Model, query, dan migrasi tidak bergantung pada driver. Untuk memindahkan
aplikasi dari SQLite ke PostgreSQL:

1. `dartisan db:install pgsql`.
2. Di `.env`: `DB_CONNECTION=pgsql` serta `DB_HOST`, `DB_PORT`,
   `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`.
3. `dartisan migrate`, atau salin data yang ada dengan `db:transfer` (di
   bawah), yang lebih dulu memigrasi database baru.

### URL database

`DB_URL` menetapkan database dengan satu nilai, seperti di Laravel 12,
sehingga `.env` yang memakainya bekerja untuk kedua framework:

```dotenv
DB_CONNECTION=pgsql
DB_URL=postgres://app:secret@db.internal:5432/shop?sslmode=require
```

Nilainya digabung seperti cara `ConfigurationUrlParser` dari Laravel
menggabungkannya, dan test Daravel membandingkan hasilnya dengan hasil
Laravel sendiri:

- Scheme menentukan driver: `postgres` dan `postgresql` berarti `pgsql`,
  `mysql2` berarti `mysql`, dan `sqlite3` berarti `sqlite`.
- Host, port, user, password, dan database yang ada di URL menggantikan
  nilai `DB_*`. Bagian yang tidak disebut mempertahankannya (`DB_PORT`,
  `DB_DATABASE`, ...). User dan password di-decode dari URL, jadi tulis `@`
  sebagai `%40`.
- Query string menambahkan opsi (`sslmode`, `charset`, `timezone`, ...);
  `true`, `false`, `null`, dan angka dibaca sesuai tipenya.

Seperti di Laravel, `DB_URL` berlaku untuk setiap koneksi bawaan, dan
`DB_CONNECTION` memilih mana yang dipakai.

### Beberapa database sekaligus

Key `DB_*` mengonfigurasi satu database. Tambahkan yang lain dengan
pengaturannya sendiri di `bootstrap/app.dart`, misalnya dari URL dalam
bentuk `DB_URL` dari Laravel:

```dart
Application.configure(basePath: basePath ?? Directory.current.path)
    .withDatabaseConnection(
      'legacy',
      (env) => ConnectionConfig.fromUrl(env.string('LEGACY_DB_URL')),
    )
```

```dotenv
LEGACY_DB_URL=mysql://shop:secret@10.0.0.5:3306/shop
```

`ConnectionConfig.fromUrl` membaca URL `pgsql://`, `mysql://`, `mariadb://`,
dan `sqlite:`, dan query string-nya menetapkan `sslmode`, `pool`, `charset`,
dan `timezone`. Koneksi yang driver-nya MySQL atau MariaDB tetap perlu
driver itu didaftarkan (`db:install mysql`).

Query dan model memilih koneksi berdasarkan nama:

```dart
final orders = await DB.table('orders', connection: 'legacy').get();

final class LegacyOrder extends Model {
  static final ModelDefinition<LegacyOrder> definition =
      ModelDefinition<LegacyOrder>(
        table: 'orders',
        connection: 'legacy',
        factory: LegacyOrder.new,
      );
  @override
  ModelDefinition<LegacyOrder> get modelDefinition => LegacyOrder.definition;
}
```

Transaksi berlaku per koneksi, seperti di Laravel. Query di koneksi lain di
dalam `DB.transaction(...)` tidak ikut bergabung, jadi tetap ter-commit
meskipun transaksinya di-rollback. `DB.transaction(..., connection:
'legacy')` memulai transaksinya sendiri di koneksi itu.

### Menyalin data antar-database

`dartisan db:transfer` menyalin data aplikasi ke database lain, misalnya
dari file SQLite yang dipakai saat development ke PostgreSQL:

```bash
dart run bin/dartisan.dart db:transfer --from=sqlite --to=pgsql://app:secret@db.internal:5432/app
dart run bin/dartisan.dart db:transfer --from=sqlite --to=pgsql --dry-run   # menghitung, tidak mengubah apa pun
```

`--from` dan `--to` menerima nama koneksi (`sqlite`, `pgsql`, nama dari
`withDatabaseConnection`) atau URL. Key `DB_*` mengonfigurasi semua koneksi
bawaan sekaligus, jadi URL adalah cara agar satu `.env` menjangkau dua
database.

- **Skema.** Target lebih dulu dimigrasi dengan migrasi milik aplikasi
  (`--no-migrate` bila sudah). Setiap database mendapat tipe kolomnya
  sendiri, bukan terjemahan DDL dari sumber. Tabel yang tidak dibuat oleh
  migrasi mana pun dicantumkan lalu dilewati, dan catatan `migrations` tidak
  pernah disalin.
- **Urutan dan atomisitas.** Tabel disalin mulai dari induknya, mengikuti
  foreign key di target, dalam satu transaksi di target. Kegagalan
  membiarkan target seperti semula. Di PostgreSQL, foreign key ditunda
  selama penyalinan dan dicek sekali di akhir, sehingga baris yang merujuk
  baris setelahnya (kategori yang induknya datang belakangan) atau tabel
  yang saling merujuk tetap tersalin. Definisinya dipulihkan sebelum commit.
- **Nilai.** `0`/`1` menjadi boolean di PostgreSQL, dokumen JSON dari
  PostgreSQL menjadi teks, dan tanggal menjadi `Y-m-d H:i:s` dari Laravel di
  SQLite dan MySQL.
- **Id.** Baris mempertahankan primary key-nya. Sequence PostgreSQL
  dilanjutkan setelah id tertinggi yang disalin, sehingga insert berikutnya
  tidak bertabrakan.
- **Keamanan.** Tabel target yang sudah berisi baris menghentikan transfer
  kecuali `--truncate` menggantikannya. Dengan `APP_ENV=production`, perlu
  `--force`. Baris dibaca dalam potongan sebesar `--chunk` (500), dipaginasi
  berdasarkan primary key. `--tables=users,posts` membatasi penyalinan.

## Migrasi

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#migration -->
```dart
final class CreatePostsTable extends Migration {
  const CreatePostsTable();

  @override
  String get name => '2026_01_01_000000_create_posts_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('posts', (table) {
    table.id();
    table.string('title');
    table.text('body').nullable();
    table.boolean('published').defaultTo(false);
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('posts');
}
```
<!-- /include -->

Migrasi dicantumkan di `bootstrap/migrations.dart` dan dicatat di tabel
`migrations` dari Laravel (`id`, `migration`, `batch`), sehingga aplikasi
Laravel dan aplikasi Daravel bisa berbagi satu catatan. Command: `migrate`,
`migrate:status`, `migrate:rollback`, `migrate:reset`, `migrate:fresh`,
`db:seed`. Di SQLite, perubahan kolom membangun ulang tabel dengan aman.

## Model

Model adalah "hybrid active record": wadah atribut ditambah
`ModelDefinition` statis yang menggantikan property ajaib dari Laravel.

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#model -->
```dart
final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title', 'body', 'published'],
    casts: {'published': Cast.boolean},
    scopes: {'published': (query, args) => query.where('published', true)},
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  static ModelQuery<Post> query() => definition.query();

  int get id => getAttr('id');
  String get title => getAttr('title');
  bool get published => getAttr('published');
}
```
<!-- /include -->

`dartisan make:model` menuliskannya untuk Anda dan `dartisan model:sync`
membangkitkan ulang accessor bertipe dari tabel. Relasi (`HasOne`,
`HasMany`, `BelongsTo`, `BelongsToMany`, `HasManyThrough`, dan
[relasi polimorfik](orm.md#relasi-polimorfik)) dideklarasikan di
`relations:` dan di-eager load dengan `with_([...])` (`with` adalah kata
yang dicadangkan di Dart). Soft delete, observer, event model, global scope,
`withCount`, dan `whereHas` (bersarang) bekerja seperti di Eloquent.

`ModelDefinition.morphClass` adalah nama kelas Laravel milik model
(`App\Models\Post` secara default). Nilai ini disimpan di kolom polimorfik
seperti `personal_access_tokens.tokenable_type`, kecuali `Relation.morphMap`
memberi model itu alias, dan dipakai di
`No query results for model [App\Models\Post] 1`.

## Query

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#query -->
```dart
await Post.query().create({'title': 'Hello', 'published': true});
await DB.table('posts').insert({'title': 'Draft'});

final published = await Post.query()
    .where('published', true)
    .orderByDesc('id')
    .get();
final titles = await DB.table('posts').orderBy('id').pluck('title');
final count = await Post.query().scope('published').count();

await DB.transaction(() async {
  final post = await Post.query().findOrFail(1);
  await post.update({'title': 'Hello, Daravel'});
});
```
<!-- /include -->

Transaksi mengikuti zone: pemanggilan bersarang menjadi savepoint, dan
callback after-commit (`App.make<DatabaseManager>().afterCommit(...)`, yang
dipakai job di queue dan `Event.dispatchAfterCommit`) hanya berjalan saat
transaksi terluar di-commit.

Dart bisa menjalankan beberapa hal sekaligus di dalam satu transaksi, hal
yang tidak bisa dilakukan PHP, jadi dua aturan menjaganya tetap aman:

- Transaksi bersarang yang dimulai bersamaan (`Future.wait([DB.transaction(...),
  DB.transaction(...)])`) berjalan satu per satu, karena savepoint di sebuah
  koneksi membentuk stack. Yang gagal hanya me-rollback pekerjaannya sendiri.
- Query yang berjalan setelah transaksinya selesai (`await` yang
  terlupakan) melempar `StateError` alih-alih berjalan di luar transaksi.
  `await` setiap query di dalam `DB.transaction`; `dartisan lint`
  (`unawaited_in_db_transaction`) menunjukkan yang tidak, termasuk
  `unawaited(...)` dan `.ignore()`.

## Kolom JSON

`->` membaca dan menulis di dalam kolom JSON, di semua driver:

```dart
await DB.table('users').where('meta->lang', 'id').get();
await DB.table('users').orderBy('meta->lang').get();
await DB.table('users').whereJsonContains('meta->roles', 'admin').get();
await DB.table('users').where('id', 1).update({
  'meta->lang': 'en',
  'meta->flags': [1, 2],
});
```

Path hanya berisi key dan indeks biasa (`items[0]->id`); selain itu adalah error,
sama seperti kolom yang tidak valid. Update mempertahankan key lain dan tipe JSON
nilainya, juga pada kolom `NULL`. Path bersarang butuh induknya di PostgreSQL dan
MySQL, sama seperti Laravel; SQLite membuatnya.

## Error query

Query yang ditolak database melempar `QueryException`, berisi `sql`,
`bindings`, `connectionName`, dan error asli driver di `previous`. Baris
yang ditolak unique index atau primary key melempar subkelasnya,
`UniqueConstraintViolationException` (SQLite, PostgreSQL `23505`,
MySQL/MariaDB `1062`), seperti di Laravel, dan seperti Laravel pula ia
menjadi 500 bila tidak ditangkap. Rule `unique` menjawab 422 sebelum insert;
exception ini menangani dua request yang sama-sama lolos pengecekan itu:

```dart
try {
  await User.query().create({'email': email, 'name': name});
} on UniqueConstraintViolationException {
  throw ValidationException.withMessages({
    'email': 'The email has already been taken.',
  });
}
```

`createOrFirst(attributes, values)` membuat barisnya atau, bila request lain
sudah membuatnya lebih dulu, mengembalikan baris itu; `firstOrCreate` dan
`updateOrCreate` memakainya, seperti di Laravel 12. Di dalam transaksi,
insert-nya berjalan dalam savepoint, sehingga insert yang ditolak tidak
membatalkan transaksi (PostgreSQL akan membatalkannya bila tidak begitu).

Berbeda dengan Laravel, pesannya mempertahankan placeholder `?` dan hanya
baris pertama dari error driver, sehingga nilai binding (hash password,
email) tidak masuk log; kata-kata database sendiri masih bisa menyebut
nilai yang bentrok (`Duplicate entry` di MySQL, detail di PostgreSQL).

## Mengulang transaksi

```dart
await DB.transaction(() async {
  // ...
}, attempts: 5);
```

Deadlock dan kegagalan serialisasi menjalankan seluruh callback lagi. Di antara
percobaan ada jeda acak 2 sampai 250 ms tanpa memegang koneksi, sehingga isolate
yang bertabrakan tidak bertabrakan lagi. Clock test yang dibekukan langsung
mengulang.

`query.poolWait` pada `DB.listen` adalah waktu menunggu koneksi, terpisah dari
`query.time`: nilai tinggi berarti pool terlalu kecil, bukan database yang lambat.
Nilainya nol di dalam transaksi, yang memegang koneksinya sendiri, dan di SQLite.

## Mendengarkan query

`DB.listen((QueryExecuted query) { ... })` dipanggil setelah setiap query
dari builder, ORM, SQL mentah, dan migrasi, dengan SQL, binding, durasi, dan
koneksinya, misalnya untuk mencatat query yang lambat:

```dart
DB.listen((query) {
  if (query.time > const Duration(milliseconds: 100)) {
    Log.warning('Slow query', {'sql': query.sql, 'ms': query.time.inMilliseconds});
  }
});
```

Tanpa listener, query tidak diukur waktunya dan tidak dilaporkan.

Untuk anggaran waktu, bukan query lambat satu per satu,
`whenQueryingForLongerThan` dari Laravel menjumlahkan query setiap request,
job, atau command dan memanggil handler sekali saat totalnya melewati
ambang:

```dart
DB.whenQueryingForLongerThan(const Duration(milliseconds: 500), (query) {
  Log.warning('Request spent over 500 ms in queries',
      {'total_ms': DB.totalQueryDuration.inMilliseconds});
});
```

`DB.withQueryCount` menjalankan callback dan mengembalikan hasilnya beserta
query yang dijalankannya, sehingga masalah N+1 berubah menjadi test yang
gagal:

```dart
final (users, count, queries) = await DB.withQueryCount(
  () => User.query().with_('posts').get(),
);
expect(count, 2); // users, lalu semua post dalam satu query
```

## Tanggal dalam query

`whereDate`, `whereYear`, `whereMonth`, dan `whereDay` membandingkan bagian
dari kolom tanggal. Shortcut dari Laravel 11 membandingkan dengan waktu saat
ini, dibaca dari `Clock` (jadi `freezeTime()` berlaku), dan menerima kolom
atau list:

| Method | Kondisi |
| :-- | :-- |
| `wherePast` / `whereNowOrPast` | sebelum / pada atau sebelum sekarang |
| `whereFuture` / `whereNowOrFuture` | setelah / pada atau setelah sekarang |
| `whereToday` | tanggalnya hari ini |
| `whereBeforeToday` / `whereTodayOrBefore` | tanggalnya sebelum / paling lambat hari ini |
| `whereAfterToday` / `whereTodayOrAfter` | tanggalnya setelah / paling cepat hari ini |

Masing-masing punya bentuk `orWhere…`, di `DB.table(...)` dan di query
model.

## Paginasi

`paginate()`, `simplePaginate()`, dan `cursorPaginate()` membaca halaman
(atau cursor) dan path absolut dari request saat ini, seperti Laravel, dan
diserialisasi ke JSON Laravel yang persis sama: key yang sama dengan urutan
yang sama, `links` dengan jendela geser dan nomor `page` dari Laravel,
`current_page_url` untuk paginasi sederhana, dan cursor yang di-encode
seperti `Cursor::encode()` dari Laravel, sehingga cursor yang diterbitkan
salah satu framework bekerja di framework lainnya. Pakai
`withQueryString()` atau `appends({...})` untuk mempertahankan parameter
query tambahan.
