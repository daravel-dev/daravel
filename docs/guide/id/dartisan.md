<!-- source: dartisan.md sha256:602a1561518b -->
# dartisan

`dartisan` adalah `artisan`-nya Daravel. Pasang sekali, lalu pakai di proyek
mana pun:

```bash
dart pub global activate dartisan_cli
dartisan new blog                       # atau --template=minimal
cd blog && dartisan migrate --seed && dartisan serve --watch
```

Di dalam proyek, `dartisan` global menjalankan CLI milik proyek itu,
`bin/dartisan.dart`, yang mengenal aplikasi Anda dan command buatan Anda
(`bootstrap/commands.dart`). `dartisan <command> --help` menampilkan opsi
sebuah command.

## Proyek

| Command | Fungsinya |
| :-- | :-- |
| `about` | Versi, environment, driver, dan path |
| `doctor [--production]` | Mengecek konfigurasi, database, storage, dan port |
| `key:generate [--show] [--force]` | Menulis `APP_KEY` baru |
| `env:encrypt`, `env:decrypt`, `env:obfuscate` | File `.env` terenkripsi, lihat [Konfigurasi](configuration.md) |
| `adopt <laravel-path> [--check]` | Berbagi database dan kunci dengan aplikasi Laravel, lihat [Migrasi dari Laravel](migrating-from-laravel.md) |
| `down [--secret] [--retry]`, `up` | Mode maintenance, lihat [Deployment](deployment.md#mode-maintenance) |
| `stub:publish` | Menyalin template generator ke `stubs/` |
| `lint [--json]` | Rule `daravel_lints` dan pengecekan registry |
| `mcp:serve [--allow-write]`, `mcp:install` | Konteks proyek untuk agen AI coding lewat MCP, lihat [di bawah](#agen-ai-coding-mcp) |
| `upgrade [--check] [--to] [--no-global] [--no-get]`, `self-update` | Memindahkan proyek dan CLI global ke sebuah rilis, lihat [di bawah](#upgrade) |
| `pub:list [--json]`, `pub:search <kata> [--online]`, `pub:add <paket...> [--yes] [--no-get]` | Mencari dan memasang paket first-party, lihat [di bawah](#paket) |
| `--version` (`-V`) | Versi CLI atau, di dalam proyek, versi framework-nya |

### Paket

`dartisan pub:add` (alias `install`) memasang paket first-party dan
menyambungkannya: dependency di `pubspec.yaml`, pemanggilan `.with*()` di
`bootstrap/app.dart`, migration dan command di registry, serta
pengaturannya di `.env.example` (tidak pernah di `.env`). Paket database
dan Redis menjalankan `db:install` dan `redis:install`.

```bash
dartisan pub:list                  # paket first-party dan yang sudah terpasang
dartisan pub:search permission     # berdasarkan nama, alias, atau deskripsi
dartisan pub:search excel --online # juga pub.dev
dartisan pub:add rbac activitylog  # beberapa sekaligus; rbac adalah alias permission
```

Nama harus cocok persis dengan paket atau alias: salah ketik berhenti
dengan "Did you mean …?" alih-alih menebak. Paket di luar Daravel dipasang
lewat `dart pub add` setelah Anda konfirmasi, atau dengan `--yes`. Tanpa
terminal, `pub:add` tidak pernah bertanya: nama yang ambigu keluar dengan
kode 64. Proyek yang memakai checkout lokal (`--path`) mengambil paket dari
checkout yang sama.

### Upgrade

`dartisan upgrade` memindahkan proyek ke rilis terbaru di pub.dev: semua
paket Daravel di `pubspec.yaml` (`daravel`, `dartisan_cli`, `daravel_test`,
`daravel_lints`, dan paket driver) di-set ke `^<versi>`, lalu
`dart pub upgrade` dijalankan, dan versi yang sama dari `dartisan` global
diaktifkan. Paket dari git atau path, serta `dependency_overrides`, tidak
diubah.

```bash
dartisan upgrade --check        # versi terpasang dan terbaru, tidak ada yang berubah
dartisan upgrade                # rilis terbaru
dartisan upgrade --to=1.8.1     # versi tertentu
dartisan self-update            # hanya dartisan global
```

`dartisan` global menjalankan keduanya sendiri, jadi keduanya juga bekerja
di proyek yang CLI-nya lebih tua dari command ini. Baca
[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md)
sebelum pindah ke versi minor baru.

## Serve, test, dan build

| Command | Fungsinya |
| :-- | :-- |
| `serve [--watch] [--isolates=N] [--embed-queue] [--embed-scheduler]` | Server HTTP; `--watch` melakukan hot reload |
| `test [--conformance] [--security] [--coverage]` | Menjalankan test |
| `build [--with-cli] [--docker [--distroless]] [--no-sqlite]` | Bundle native di `build/server/bundle`, opsional `Dockerfile` (`--distroless`: tanpa shell, non-root, lihat [Deployment](deployment.md#docker)); `--no-sqlite` tidak menyertakan library SQLite (aplikasi PostgreSQL/MySQL) |
| `route:list` | Tabel route |
| `openapi:generate [--output]` | OpenAPI 3.1 dari route dan metadata yang dideklarasikan |
| `client:flutter [--output] [--package-name] [--prefix] [--state] [--watch]` | Paket client Dart/Flutter bertipe dari route, dengan rule validasi milik server ([Client Flutter](flutter-client.md)) |

## Database

| Command | Fungsinya |
| :-- | :-- |
| `migrate [--seed [--force]]`, `migrate:status` | Migrasi (seeding ditolak di produksi tanpa `--force`) |
| `migrate:rollback [--step] [--force]`, `migrate:reset [--force]` | Membatalkan batch terakhir, atau semuanya (ditolak di produksi tanpa `--force`) |
| `migrate:fresh [--seed] [--force]` | Menghapus semua tabel lalu migrasi lagi (ditolak di produksi tanpa `--force`) |
| `db:seed [--class] [--force]` | Menjalankan seeder (ditolak di produksi tanpa `--force`) |
| `db:show`, `db:table <table> [--limit]` | Tabel, kolom, dan baris |
| `db:install <driver> [--no-get]` | Menambahkan paket driver (`sqlite`, `pgsql`, `mysql`, `mariadb`) dan mendaftarkannya ([Database](database.md#driver-dan-koneksi)) |
| `redis:install [--docker] [--server=valkey\|redis] [--no-get]` | Menambahkan daravel_redis, mendaftarkan `.withRedis()` beserta command-nya, mendokumentasikan key `.env`-nya, dan dengan `--docker` sebuah service Valkey ([Redis](redis.md)) |
| `db:transfer --from --to [--dry-run] [--truncate] [--tables] [--no-migrate]` | Menyalin data ke database lain, setelah lebih dulu memigrasinya ([Database](database.md#menyalin-data-antar-database)) |
| `db:backup [--output] [--keep=N]` | Backup database SQLite saat server berjalan ke `storage/backups` (lihat [Deployment](deployment.md#backup)) |
| `tinker "<expression>"` | Mengevaluasi ekspresi Dart di aplikasi yang sudah di-boot |
| `model:sync [Model]` | Membangkitkan ulang accessor bertipe sebuah model dari tabelnya |
| `model:show <Model> [--json]` | Tabel, atribut (tipe, cast, fillable, hidden), dan relasi sebuah model, dari `bootstrap/models.dart` |
| `daragic:export [--out] [--only]` | Model aplikasi (DAM) untuk `daragic`: route, model, migrasi, skema, jadwal, ... (lihat [Migrasi dari Laravel](migrating-from-laravel.md#model-aplikasi-daragic)) |

## Queue dan penjadwalan

| Command | Fungsinya |
| :-- | :-- |
| `queue:work [--queue] [--tries] [--max-time] [--stop-when-empty]` | Memproses job; berhenti setelah job yang sedang berjalan saat `SIGTERM` |
| `queue:failed`, `queue:retry`, `queue:forget`, `queue:flush` | Job yang gagal |
| `queue:clear`, `queue:pause`, `queue:continue`, `queue:restart` | Kendali queue |
| `schedule:work`, `schedule:run`, `schedule:list` | Scheduler |
| `cache:clear`, `storage:link`, `coordinator:stats [--url] [--token] [--json]` | Cache, link storage publik, coordinator server yang sedang berjalan beserta saran ([Operasional](operations.md#yang-dipantau)) |

## Generator

`make:model [-m -f -s -c -p -r --api --all]`, `make:migration`,
`make:seeder`, `make:factory`, `make:controller [--api --resource --model]`,
`make:request`, `make:middleware`, `make:job`, `make:policy`, `make:event`,
`make:listener`, `make:resource`, `make:rule`, `make:mail`,
`make:notification`, `make:observer`, `make:query-filter` (daravel_teorion),
`make:provider`, `make:command`, dan
`make:test`. Masing-masing menulis file dari template dan menambahkannya ke
registry yang sesuai di `bootstrap/`.

## Agen AI coding (MCP)

`dartisan mcp:serve` adalah server [Model Context
Protocol](https://modelcontextprotocol.io) lewat stdio, padanan Laravel
Boost di Daravel. Server ini mem-boot aplikasi proyek, sehingga agen melihat
aplikasi sebagaimana adanya, bukan tebakan:

| Tool | Menjawab dengan |
| :-- | :-- |
| `about` | Versi Daravel dan Dart, environment, driver |
| `routes` | Method, URI, nama, action, middleware, rule validasi beserta JSON Schema-nya, respons yang didokumentasikan |
| `schema` | Tabel beserta jumlah kolom dan baris, atau kolom satu tabel |
| `models` | Model yang terdaftar beserta relasinya, atau atribut, key, dan relasi satu model |
| `db_query` | Satu statement `SELECT`/`WITH`/`EXPLAIN`, paling banyak 100 baris secara default; selalu di-rollback, dan read-only di level database pada SQLite (`query_only`) dan PostgreSQL (`READ ONLY`) |
| `read_logs`, `last_error` | Record terbaru dari file log harian (`LOG_STACK` dengan `daily`), atau error terbaru |
| `conventions` | Registry, generator, pola model, waktu, format Laravel yang dikunci, rule lint |
| `docs_search` | Bagian paling relevan dari panduan ini, untuk versi yang terpasang |
| `run_command` | Menjalankan command dartisan (hanya dengan `--allow-write`) |

Server ini read-only kecuali dijalankan dengan `--allow-write`. Bahkan
dengan itu, `run_command` menolak command yang berjalan lama (`serve`,
`queue:work`, `schedule:work`, `tinker`) dan, dengan `APP_ENV=production`,
command yang destruktif (`migrate:fresh`, `migrate:reset`,
`migrate:rollback`, `db:seed`, `queue:flush`, `queue:clear`,
`key:generate`, `env:decrypt`, `env:encrypt`, `down`). Pesan protokol
memakai stdout; log masuk ke stderr.

Paket menambahkan tool lewat command yang mereka daftarkan: command yang
merupakan `McpToolSource` membawa `McpTool`-nya. Dengan `redisCommands` di
`bootstrap/commands.dart`, agen mendapat `redis_inspect` (isi sebuah key,
atau key dari sebuah pola; nilainya disembunyikan di production). Tool yang
menulis hanya ditawarkan dengan `--allow-write`.

`dartisan mcp:install` menyiapkan proyek untuk agen, seperti
`boost:install` dari Laravel:

```bash
dart run bin/dartisan.dart mcp:install                          # .mcp.json + AGENTS.md
dart run bin/dartisan.dart mcp:install --guidelines=CLAUDE.md   # pedoman di file lain
dartisan new blog --mcp                                         # sama, untuk proyek baru
```

Command ini menambahkan server `daravel` ke `.mcp.json` (server lain
dipertahankan; `--force` mengganti entri `daravel` yang sudah ada) dan
menulis konvensi Daravel di antara penanda `<!-- daravel:guidelines -->` di
`AGENTS.md`. Menjalankannya lagi setelah upgrade memperbarui bagian itu dan
membiarkan sisa file. Claude Code membaca `.mcp.json` dari proyek; untuk
mendaftarkan server secara manual:

```bash
claude mcp add daravel -- dart run bin/dartisan.dart mcp:serve
```

Entri `.mcp.json`, yang juga dibaca client MCP lain:

```json
{
  "mcpServers": {
    "daravel": {
      "command": "dart",
      "args": ["run", "bin/dartisan.dart", "mcp:serve"]
    }
  }
}
```

### DDEV

Di proyek [DDEV](https://ddev.com) (yang punya `.ddev/config.yaml`), paket
di-resolve di dalam web container, jadi `dart` di host tidak bisa
menjalankan CLI proyek. `mcp:install` mengenali ini dan mendaftarkan server
di dalam container:

```json
{
  "mcpServers": {
    "daravel": {
      "command": "ddev",
      "args": ["dartisan", "mcp:serve"]
    }
  }
}
```

Command ini juga menambahkan custom command `.ddev/commands/web/dartisan`
bila belum ada, sehingga `ddev dartisan migrate` dan command lain juga
berjalan di container. Entri yang masih berisi default host (`dart run ...`)
diganti, karena tidak bisa berjalan di sana. Entri yang sudah Anda ubah
dipertahankan. Setelah menambahkan DDEV ke proyek yang sudah ada, jalankan
lagi `ddev dartisan mcp:install`. `dartisan new --mcp` berjalan sebelum DDEV
dikonfigurasi, jadi yang ditulis adalah entri untuk host.

## Command buatan sendiri

```dart
final class SendReports extends DaravelCommand {
  SendReports(super.createApp);

  @override
  String get name => 'reports:send';

  @override
  String get description => 'Email the weekly reports.';

  @override
  Future<int> run() => withApp((app) async {
    // Aplikasi sudah di-boot; facade bisa dipakai di sini.
    return 0;
  });
}
```

`dartisan make:command SendReports` menulis ini dan mendaftarkannya di
`bootstrap/commands.dart`.
