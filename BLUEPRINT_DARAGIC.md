# DARAGIC — BLUEPRINT GENERATOR DUA ARAH LARAVEL ⇄ DARAVEL

> **Status:** Draft arsitektur, tahap pra-implementasi · **Tanggal:** 2026-10-23 · **Versi:** 1.2 (ADR-D01…D06 ditetapkan pemilik proyek, 2026-10-23; tidak ada pertanyaan terbuka tersisa)
> **Hubungan dokumen:** memperdalam dan **menggantikan** Bagian 16 `BLUEPRINT_V2.md` (Bagian 16 tetap sebagai ringkasan). Mengasumsikan keputusan ADR-001…023 di V2.1 berlaku.
> **Bahasa:** prosa Indonesia; kode, identifier, dan istilah teknis dalam bahasa Inggris.
> **Nama:** `daragic` = *Daravel magic / Laravel magic*. Satu nama untuk dua arah: `to-daravel` dan `to-laravel`.
> **Target kompatibilitas awal:** Laravel 10, 11, 12 (PHP 8.2+) ⇄ Daravel 1.x (Dart ^3.9).

---

## 0. Cara Membaca

Dokumen ini adalah spesifikasi *tool*, bukan framework. Ia menjawab lima pertanyaan secara berurutan: **apa yang dijanjikan** (Bagian 1–3), **bagaimana aplikasi direpresentasikan** (Bagian 4–5), **bagaimana diekstrak dan diterjemahkan** (Bagian 6–10), **bagaimana dibuktikan benar** (Bagian 11–15), dan **bagaimana dijalankan sebagai produk** (Bagian 16–24). Lampiran berisi contoh end-to-end.

Konvensi: `DARAGIC-TODO` = penanda di kode hasil generate untuk konstruksi yang tidak dapat diterjemahkan; `DAM` = Daravel Application Model (IR); `Dialect` = subset bahasa yang didukung transpiler; `parity.yaml` = tabel paritas simbol; `equivalence.yaml` = pemetaan package pihak ketiga.

---

## 1. Ringkasan Eksekutif

`daragic` mengubah migrasi Laravel → Daravel dari proyek penulisan ulang menjadi **proses yang terukur, bertahap, dan dapat dibalik**. Tesisnya: aplikasi Laravel sangat konvensional, dan Laravel sendiri menyediakan API introspeksi runtime (`Route::getRoutes()`, refleksi model, `Gate::policies()`, `Schema::getColumns()`, `Schedule::events()`), sehingga **sebagian besar aplikasi dapat dibaca sebagai data, bukan sebagai teks PHP**. Data itu dituangkan ke IR berversi (DAM), lalu dipancarkan sebagai proyek Daravel oleh generator `dartisan make:*` yang sama dengan yang dipakai manusia. Hanya **badan metode** yang memerlukan transpiler, dan untuk itu `daragic` memakai subset terbatas dengan jaminan: **hasil selalu terkompilasi**, konstruksi yang tidak didukung menjadi `DARAGIC-TODO` dengan sumber asli, dan laporan cakupan menyebut angka per lapisan.

Empat kemampuan yang membedakan `daragic` dari "konverter kode" biasa:

1. **Pre-migration linter** (`daragic analyze`) memberi **skor kesiapan** dan saran refactor di PHP *sebelum* migrasi, sehingga tim tahu usaha yang dibutuhkan.
2. **Test lama menjadi spesifikasi migrasi**: test feature Laravel dikonversi ke `TestClient` Daravel; hijau berarti perilaku terjaga.
3. **Differential replay**: trafik nyata yang direkam di staging Laravel diputar ulang ke Daravel dan di-diff secara terstruktur, menguji kode yang tidak punya test.
4. **Dua arah dan inkremental**: IR yang sama memancarkan Laravel dari Daravel (jaminan keluar), dan ekspor ulang dari Laravel yang masih berkembang digabung tiga-arah tanpa menimpa suntingan manusia.

Yang **tidak** dijanjikan: transpilasi PHP arbitrer. Fitur dinamis PHP (`eval`, variable variables, `__call` kustom, Livewire) ditandai sebagai pekerjaan manual sejak tahap `analyze`.

---

## 2. Tujuan, Non-Tujuan, Persona, dan Perjalanan Pengguna

### 2.1 Tujuan

| # | Tujuan | Ukuran keberhasilan (diukur pada korpus, Bagian 19) |
| :-- | :-- | :-- |
| G1 | Konversi struktural otomatis (rute, model, relasi, migrasi, FormRequest, resource, policy, job, event, schedule, config, env, seeder, factory, middleware) | 100% artefak deklaratif pada korpus terkonversi tanpa TODO |
| G2 | Konversi badan metode untuk subset Laravel konvensional | ≥ 90% pernyataan pada korpus API-starter tanpa TODO; angka korpus lain dilaporkan apa adanya |
| G3 | Hasil selalu terkompilasi dan teranalisis bersih | `dart analyze` 0 error pada 100% keluaran |
| G4 | Verifikasi otomatis (test terkonversi, replay, schema diff) | Test terkonversi berjalan; diff replay 0 pada rute yang dicakup |
| G5 | Arah balik Daravel → Laravel untuk artefak struktural + test | Round-trip Laravel → Daravel → Laravel menghasilkan skema & rute identik |
| G6 | Konversi package Laravel Tier A/B | 10 package terpopuler memiliki port/konversi terverifikasi |
| G7 | Inkremental: ekspor ulang tidak menimpa suntingan manusia | Merge 3-arah dengan konflik eksplisit, nol kehilangan suntingan |

### 2.2 Non-Tujuan (eksplisit)

- Bukan interpreter PHP di Dart, bukan runtime kompatibilitas PHP.
- Tidak mengonversi Livewire, Filament, Nova, atau UI berbasis PHP-dinamis (diklasifikasikan Tier C sejak `analyze`).
- Tidak menjanjikan ekuivalensi bit-per-bit untuk floating point, format tanggal lokal, atau urutan hasil query tanpa `ORDER BY`.
- Tidak memigrasi data (DB dipakai bersama; migrasi skema hanya ketika diminta).
- Tidak mengganti kebutuhan review manusia atas kode bisnis kritis.

### 2.3 Persona

| Persona | Kebutuhan | Fitur kunci |
| :-- | :-- | :-- |
| **Tim Laravel yang ingin performa/single-binary** | Pindah bertahap tanpa menghentikan pengembangan | `analyze`, koeksistensi per-endpoint, re-import inkremental |
| **Tim Flutter + Laravel** | Satu bahasa end-to-end | Konversi + `client:generate` dari OpenAPI Daravel |
| **Tim yang ragu** | Jaminan bisa kembali | `to-laravel` (round-trip), kontrak kompatibilitas |
| **Pembuat package Laravel** | Menjangkau pengguna Daravel tanpa menulis ulang | DPS manifest, `package:convert`, atribut anotasi |
| **Konsultan migrasi** | Estimasi usaha & laporan untuk klien | Skor kesiapan, `MIGRATION_REPORT.md`, estimasi jam |

### 2.4 Perjalanan Pengguna Utama (Laravel → Daravel, koeksistensi)

1. `composer require --dev daravel/daragic` → `php artisan daragic:analyze` → membaca skor (mis. 82/100), daftar 14 TODO potensial, 2 package Tier C.
2. Refactor kecil di PHP sesuai saran (tambahkan tipe PHPStan pada 6 metode, ganti 2 `DB::raw` dengan builder).
3. `php artisan daragic:export --out=../dam` (DAM + sources + views + tests).
4. `dartisan daragic:import ../dam --into=../app-dart` → proyek Daravel; `dartisan daragic:verify` → analyze bersih, 61/64 test hijau, 3 TODO di satu service.
5. Perbaiki 3 TODO (±2 jam), test hijau.
6. Rekam trafik staging seminggu (`daragic:record`), `dartisan daragic:replay` → 0 diff pada 48 rute, 2 diff pada format tanggal → perbaiki cast.
7. Deploy koeksistensi: nginx mengarahkan `/api/v2/*` ke binary Daravel, sisanya ke PHP-FPM; DB & Redis bersama; feature flag per rute.
8. Setiap sprint: `daragic:export` ulang → `daragic:import --merge` menggabungkan perubahan Laravel yang baru; endpoint berpindah bertahap; pada akhirnya PHP-FPM dimatikan — atau, bila keputusan berbalik, `dartisan daragic:export --to-laravel` mengembalikan artefak ke Laravel.

---

## 3. Prinsip Desain

| # | Prinsip | Konsekuensi |
| :-- | :-- | :-- |
| D1 | **Introspeksi runtime dulu, AST kemudian** | Ekstraksi rute/model/relasi/policy/skema memakai API Laravel yang sudah "mengerti" aplikasi; AST hanya untuk badan metode dan pemetaan `env()` |
| D2 | **Satu IR untuk dua arah** | DAM adalah kontrak publik berversi; extractor & emitter di kedua sisi hanya berbicara DAM |
| D3 | **Emitter = generator resmi** | `dartisan make:*` dan `php artisan make:*` dipakai ulang; tidak ada jalur kode kedua, hasil identik dengan buatan manusia |
| D4 | **Selalu terkompilasi** | Konstruksi tak didukung → `throw DaragicTodo(...)` + sumber asli sebagai komentar + entri laporan; file tidak pernah rusak |
| D5 | **Semantik PHP dijaga dulu, idiom Dart kemudian** | Mode `faithful` memakai helper `php_compat` (`truthy`, `looseEquals`, `phpEmpty`); mode `idiomatic`/`modernize` menggantinya hanya bila tipe membuktikan aman |
| D6 | **Paritas terukur** | `parity.yaml` diverifikasi test arsitektur di Daravel; dokumentasi side-by-side dibangkitkan darinya |
| D7 | **Verifikasi adalah produk** | Test terkonversi, replay, schema diff, dan laporan bukan opsional |
| D8 | **Tidak menimpa manusia** | Marker region + merge 3-arah + `daragic.lock`; suntingan manusia selalu menang pada konflik |
| D9 | **Aman dijalankan** | Extractor berjalan di sandbox (`APP_ENV=daragic`, DB scratch, driver mail/queue/http dinonaktifkan), rahasia tidak pernah masuk DAM |
| D10 | **Jujur dalam angka** | Semua klaim cakupan berasal dari korpus publik yang dapat direproduksi |

---

## 4. Arsitektur & Komponen

### 4.1 Diagram

```text
 LARAVEL (PHP 8.2+)                          DAM (IR, JSON Schema v1)                    DARAVEL (Dart ^3.9)
┌───────────────────────────────┐          ┌──────────────────────────┐          ┌───────────────────────────────┐
│ composer: daravel/daragic     │          │ dam.json                 │          │ pub: daragic (CLI + lib)      │
│  ├ Sandbox booter             │  export  │ sources/**/*.ir.json     │  import  │  ├ DAM reader/validator       │
│  ├ Extractors (runtime API)   │ ───────▶ │ views/**/*.blade.php     │ ───────▶ │  ├ Emitter Dart               │
│  ├ PHP AST (nikic/php-parser) │          │ lang/**, tests/**        │          │  │   (dartisan make:* + stubs)│
│  │   + PHPStan type dump      │          │ recordings/** (opsional) │          │  ├ Dialect → Dart codegen     │
│  ├ Dialect lowering (PHP→IR)  │          │ daragic.lock             │          │  ├ Blade compiler             │
│  ├ Emitter PHP (reverse)      │ ◀─────── │                          │ ◀─────── │  ├ Extractor Daravel          │
│  ├ Recorder middleware        │  import  └──────────────────────────┘  export  │  ├ Dialect lowering (Dart→IR) │
│  └ Readiness analyzer         │                      ▲                         │  ├ Replayer + differ          │
└───────────────────────────────┘                      │                         │  └ Report generator           │
                 ▲                      parity.yaml · equivalence.yaml            └───────────────────────────────┘
                 └────────────────── repo bersama: daravel/parity (berversi) ───────────────────┘
```

### 4.2 Repositori & Paket

| Repo / paket | Bahasa | Isi |
| :-- | :-- | :-- |
| `daravel/daragic` (Packagist) | PHP | Artisan commands `daragic:*` **dan** binary `vendor/bin/daragic` (ADR-D06), extractors, sandbox booter, Dialect lowering PHP→IR, emitter PHP, PHPStan extension `daragic/phpstan-types` (dump tipe) |
| `daravel/daragic-attributes` (Packagist) | PHP | Atribut `#[Daragic\...]` tanpa dependensi runtime |
| `daragic` (pub.dev) | Dart | `dartisan daragic:*` commands (terpasang sebagai plugin `dartisan_cli`), DAM reader, emitter Dart, Dialect→Dart codegen, Blade compiler, replayer, report |
| `daravel` (`package:daravel/php_compat.dart`) | Dart | Helper semantik PHP (`truthy`, `looseEquals`, `phpEmpty`, `phpStrlen`, `phpCompare`, `mapAsync`, …) — bagian framework agar kode hasil generate tanpa dependensi ekstra |
| `daravel/parity` (GitHub) | YAML | `parity.yaml`, `equivalence.yaml`, korpus golden, JSON Schema DAM; dirilis berversi `laravel-12/daravel-1` |
| `daravel/corpus` (GitHub) | PHP+Dart | Aplikasi korpus publik & hasil konversi referensi (Bagian 19) |

### 4.3 Alur Data Ringkas

`Laravel app` → (sandbox boot) → `extractors` → `DAM` + `sources/*.ir.json` (badan metode dalam Dialect IR) → `dartisan daragic:import` → (emitter: generators + codegen + Blade compiler) → `Daravel app` + `MIGRATION_REPORT.md` → `verify` (analyze, test, schema diff, replay). Arah balik simetris dengan `dartisan daragic:export` dan `php artisan daragic:import`.

---

## 5. DAM — Daravel Application Model (Spesifikasi IR)

### 5.1 Prinsip Skema

- **Deklaratif dan bahasa-netral**: DAM menggambarkan *apa* (rute, model, aturan), bukan *bagaimana* dalam PHP/Dart. Badan metode disimpan terpisah di `sources/` sebagai Dialect IR (Bagian 8) dan dirujuk lewat `source: {path, hash}`.
- **Berversi dan dapat divalidasi**: `damVersion` semver; JSON Schema diterbitkan di `daravel/parity`; `daragic` menolak DAM dengan major berbeda dan memigrasi minor otomatis.
- **Lossless untuk yang dikenal, transparan untuk yang tidak**: setiap entitas boleh membawa `unsupported: [...]` dan `raw: {...}` (data asli yang tidak dipetakan) agar tidak ada informasi hilang diam-diam.
- **Deterministik**: urutan entitas stabil (diurutkan nama) sehingga diff DAM antar ekspor bermakna; `daragic.lock` menyimpan hash per entitas untuk merge inkremental.
- **Tanpa rahasia**: nilai env tidak diekspor; hanya kunci, default, dan pemetaan `config path → env key`.

### 5.2 Bagian-bagian DAM

| Bagian | Isi inti | Sumber ekstraksi (Laravel) |
| :-- | :-- | :-- |
| `meta` | `damVersion`, framework & versi, PHP, waktu, `tool` versi, `parityVersion` | — |
| `app` | nama, timezone, locale, fallback locale, `url`, debug flag (nilai bukan rahasia) | `config('app')` |
| `env` | daftar kunci `.env.example`, default, tipe terinferensi, `usedBy: [config.database.host]` | `.env.example` + AST `env()` |
| `config` | pohon config penuh dengan nilai non-rahasia; nilai yang berasal dari `env()` diganti `{"$env": "KEY", "default": ...}`; closure → `{"$source": ...}` | runtime `config()->all()` + AST |
| `middleware` | global, grup, alias, prioritas, parameter | Kernel/Router |
| `routes` | metode, uri, nama, aksi (controller+method / closure source / view / redirect), middleware (sudah di-*flatten* + grup asli), `where`, domain, prefix, binding (`{user}` → model + kolom), `scopeBindings`, `withoutMiddleware`, `defaults` | `Route::getRoutes()` |
| `controllers` | kelas, konstruktor (DI), metode publik + `source`, middleware controller | Reflection + AST |
| `models` | tabel, key, fillable/guarded, casts, hidden/visible/appends, timestamps, softDeletes, koneksi, relasi (tipe, related, kunci, pivot, morph), scopes (source), accessors/mutators (`getXAttribute`, `Attribute::make` → source), observers & event listeners, global scopes, `touches`, `perPage`, `with` default, `withCount` default | Reflection + invokasi relasi + AST |
| `validation` | FormRequest: rules (string DSL **dan** representasi objek untuk `Rule::` kelas), messages, attributes, authorize source, `prepareForValidation` source; aturan kustom (kelas `ValidationRule`) → source + tier | Instansiasi + AST |
| `resources` | JsonResource/ResourceCollection: `toArray` source, `with`, `withoutWrapping` | AST |
| `policies` & `gates` | model → policy, abilities + source; `Gate::define` closures → source | `Gate::policies()`, `Gate::abilities()` + AST |
| `jobs` | kelas, properti/konstruktor (tipe), `tries/backoff/timeout/maxExceptions/queue/connection`, `uniqueId`, middleware, `handle` source, `failed` source | Reflection + AST |
| `events` | event → listeners (sync/queued), subscriber, event props (tipe), `ShouldBroadcast` + channel (T2) | `Event::getRawListeners()` + AST |
| `schedule` | entri: jenis (command/job/call/exec), ekspresi cron, timezone, flags (`withoutOverlapping`, `onOneServer`, `runInBackground`, `evenInMaintenanceMode`), environments, hooks source | `Schedule::events()` |
| `migrations` | daftar terurut: nama, batch (dari tabel `migrations` bila ada), operasi terstruktur (`create/table/drop/rename` + kolom/indeks/FK) **atau** `raw` SQL, `withinTransaction` | Recording Blueprint (6.6) + AST fallback |
| `schema` | keadaan aktual: tabel, kolom (tipe, nullable, default, auto-increment), indeks, FK, views | `Schema::get*` (L11+) / dbal (L10) |
| `seeders` & `factories` | kelas, urutan `call`, definisi factory (`definition()` source, states, `afterCreating`) | Reflection + AST |
| `views` | daftar Blade: path, direktif yang dipakai, komponen yang dirujuk, `@php` blok, hal tak didukung | Blade parser |
| `lang` | file bahasa (PHP array → JSON), JSON lang | runtime `trans()` loader |
| `commands` | Artisan command kustom: signature, description, `handle` source | `Artisan::all()` + AST |
| `packages` | composer.lock: nama, versi, lisensi, provider, tier (A/B/C) + `equivalence` | composer + `equivalence.yaml` |
| `tests` | kelas test (PHPUnit/Pest), jenis (feature/unit), source | AST |
| `report` | hasil `analyze`: skor, TODO potensial, blocker | analyzer |

### 5.3 Cuplikan Skema (JSON Schema, disederhanakan)

```json
{
  "$id": "https://daravel.dev/schemas/dam-1.0.json",
  "type": "object",
  "required": ["meta", "app", "routes", "models", "migrations"],
  "properties": {
    "meta": { "type": "object", "required": ["damVersion", "source"], "properties": {
      "damVersion": { "const": "1.0" },
      "source": { "properties": { "framework": { "enum": ["laravel", "daravel"] }, "version": { "type": "string" } } } } },
    "models": { "type": "array", "items": { "$ref": "#/$defs/Model" } },
    "routes": { "type": "array", "items": { "$ref": "#/$defs/Route" } }
  },
  "$defs": {
    "Source": { "type": "object", "required": ["path", "hash", "lang"], "properties": {
      "path": { "type": "string" }, "hash": { "type": "string" }, "lang": { "enum": ["php", "dart"] },
      "coverage": { "type": "number" }, "todos": { "type": "array" } } },
    "Relation": { "type": "object", "required": ["name", "type", "related"], "properties": {
      "type": { "enum": ["hasOne", "hasMany", "belongsTo", "belongsToMany", "hasOneThrough", "hasManyThrough", "morphOne", "morphMany", "morphTo", "morphToMany", "morphedByMany"] },
      "foreignKey": { "type": "string" }, "localKey": { "type": "string" }, "ownerKey": { "type": "string" },
      "pivot": { "type": "object", "properties": { "table": {}, "foreignPivotKey": {}, "relatedPivotKey": {}, "withPivot": {}, "withTimestamps": {}, "using": {} } },
      "morph": { "type": "object", "properties": { "type": {}, "id": {}, "map": {} } },
      "through": { "type": "object" }, "constraints": { "$ref": "#/$defs/Source" } } },
    "Model": { "type": "object", "required": ["name", "table", "key"], "properties": {
      "name": {}, "fqcn": {}, "table": {}, "connection": {},
      "key": { "properties": { "name": {}, "type": { "enum": ["autoInt", "uuid", "ulid", "string", "int"] }, "incrementing": {} } },
      "fillable": {}, "guarded": {}, "casts": { "type": "object" }, "hidden": {}, "visible": {}, "appends": {},
      "timestamps": {}, "createdAt": {}, "updatedAt": {}, "softDeletes": {}, "deletedAt": {},
      "relations": { "type": "array", "items": { "$ref": "#/$defs/Relation" } },
      "scopes": { "type": "object" }, "globalScopes": {}, "accessors": {}, "mutators": {}, "observers": {},
      "unsupported": { "type": "array" }, "raw": { "type": "object" } } },
    "Route": { "type": "object", "required": ["methods", "uri", "action"], "properties": {
      "methods": {}, "uri": {}, "name": {}, "domain": {},
      "action": { "oneOf": [ { "properties": { "kind": { "const": "controller" }, "class": {}, "method": {} } },
                             { "properties": { "kind": { "const": "closure" }, "source": { "$ref": "#/$defs/Source" } } },
                             { "properties": { "kind": { "enum": ["view", "redirect"] } } } ] },
      "middleware": { "type": "array" }, "middlewareGroups": {}, "where": {}, "bindings": {}, "scopeBindings": {}, "formRequest": {} } }
  }
}
```

### 5.4 Representasi Aturan Validasi

Dua bentuk disimpan bersamaan agar emitter bebas memilih: `dsl: "required|string|max:32|unique:products,sku"` dan `rules: [{name: required}, {name: string}, {name: max, args: [32]}, {name: unique, args: {table: products, column: sku, ignore: null}}]`. Objek `Rule::` Laravel dipetakan ke bentuk terstruktur: `Rule::unique/exists/in/notIn/dimensions/enum/password/file/imageFile/when/requiredIf/excludeIf/prohibitedIf`. Kelas aturan kustom (`ValidationRule`) menjadi `{name: custom, class: App\Rules\Nik, source: ...}` → Daravel `Rule.custom`/kelas `Nik extends Rule` hasil transpilasi.

### 5.5 Kebijakan Versi DAM

`1.x` menambah field opsional saja; perubahan makna field = `2.0`. `daragic` mencetak `damVersion` yang didukung; file `daragic.lock` menyimpan `damVersion`, `parityVersion`, hash per entitas, dan peta file hasil generate → entitas (untuk merge).

---

## 6. Extractor Laravel (sisi PHP)

### 6.1 Sandbox Boot

Extractor mem-boot aplikasi **sekali** di lingkungan terkendali agar introspeksi runtime aman dan deterministik:

- `APP_ENV=daragic`, `APP_DEBUG=false`, `.env.daragic` otomatis: `DB_CONNECTION=sqlite`, `DB_DATABASE=:memory:` (atau `--db=<dsn>` untuk DB salinan read-only ketika skema aktual dibutuhkan), `CACHE_STORE=array`, `SESSION_DRIVER=array`, `QUEUE_CONNECTION=sync`, `MAIL_MAILER=array`, `BROADCAST_CONNECTION=null`, `LOG_CHANNEL=null`.
- `Http::preventStrayRequests()` (Laravel 9.2+) mencegah HTTP keluar; `Mail::fake()`, `Notification::fake()`, `Queue::fake()`, `Event::fake()` **tidak** dipakai (akan menyembunyikan listener) — sebagai gantinya dispatcher dibungkus pencatat.
- Provider pihak ketiga yang gagal boot di sandbox dicatat dan dilewati (`--skip-provider=`), dengan dampak dilaporkan (entitas dari provider itu diekstrak via AST saja).
- Dilarang keras di produksi: perintah menolak bila `APP_ENV=production` kecuali `--i-know-what-i-am-doing` dan selalu read-only terhadap DB (`--db` memakai transaksi yang di-rollback + `SET TRANSACTION READ ONLY` di Postgres/MySQL).

### 6.2 Rute & Middleware

- `Route::getRoutes()` → untuk setiap `Illuminate\Routing\Route`: `methods()`, `uri()`, `getName()`, `getDomain()`, `getAction()` (`controller`, `uses`, `as`, `prefix`, `where`, `middleware`, `excluded_middleware`, `missing`), `gatherMiddleware()` (hasil flatten) **dan** `middleware()` (grup asli, agar bisa dipetakan ke alias Daravel), `wheres`, `parameterNames()`, `bindingFields()` (`{post:slug}`), `defaults`, `enforcesScopedBindings()`, `isFallback`, `withTrashedBindings()`.
- Closure route: lokasi via `ReflectionFunction::getFileName/StartLine/EndLine` → AST → Dialect.
- Middleware: `Router::getMiddlewareGroups()`, `Router::getMiddleware()` (alias), `Kernel::getGlobalMiddleware()` (L11: dari `bootstrap/app.php` via `Illuminate\Foundation\Configuration\Middleware`), prioritas `$middlewarePriority`; middleware kustom aplikasi → `handle` source + daftar parameter.
- Pemetaan ke Daravel: alias via `parity.middlewareAliases`; middleware bawaan Laravel yang tidak ada padanannya (mis. `SubstituteBindings` — implisit di Daravel) dihilangkan dengan catatan.

### 6.3 Model & Relasi

Untuk setiap kelas di `app/Models` (dan namespace lain yang `extends Model`, ditemukan via Composer classmap):

- Instansiasi tanpa DB: `new $class` lalu `getTable()`, `getKeyName()`, `getKeyType()`, `getIncrementing()`, `getFillable()`, `getGuarded()`, `getCasts()` (termasuk `datetime:format`, `encrypted`, `AsArrayObject`, enum class, custom `CastsAttributes` → source + tier), `getHidden()`, `getVisible()`, `getAppends()`, `usesTimestamps()`, `getCreatedAtColumn()`, `getUpdatedAtColumn()`, `getConnectionName()`, `getPerPage()`, `getTouchedRelations()`, `getGlobalScopes()`, `getDeletedAtColumn()` bila memakai `SoftDeletes` (`class_uses_recursive`), `HasUuids`/`HasUlids` trait → `keyType`.
- **Relasi** (teknik `laravel-ide-helper`): untuk setiap metode publik tanpa parameter wajib dan bukan dari `Model`, periksa return type `Relation` **atau** invoke pada instance kosong dalam `try/catch` (query tidak dieksekusi); dari objek `Relation` ambil: `getRelated()::class`, `HasOneOrMany::getForeignKeyName()/getLocalKeyName()`, `BelongsTo::getForeignKeyName()/getOwnerKeyName()`, `BelongsToMany::getTable()/getForeignPivotKeyName()/getRelatedPivotKeyName()/getPivotColumns()/withTimestamps` (properti publik `withTimestamps` ada; `using` pivot class via `getPivotClass()`), `HasManyThrough::getFirstKeyName()/getForeignKeyName()/getLocalKeyName()/getSecondLocalKeyName()/getThroughParent()`, `MorphTo::getMorphType()`, `MorphOneOrMany::getMorphType()/getForeignKeyName()`, `MorphToMany::getTable()/getMorphClass()`. Constraint tambahan dalam metode relasi (`->where('active', true)`, `->orderBy`) dideteksi dari AST metode dan disimpan sebagai `constraints.source`.
- Morph map: `Relation::morphMap()`.
- Scopes lokal: metode `scopeXxx` → AST; accessor/mutator lama `getXxxAttribute/setXxxAttribute` dan baru `Attribute::make(get:, set:)` → AST; `casts()` metode (L11) → runtime `getCasts()` sudah mencakup.
- Observers & events: `#[ObservedBy]` (L10.44+) via refleksi atribut; `Model::observe()` dalam provider via AST `boot()`; `$dispatchesEvents` properti via refleksi; listener kelas via `Event::getRawListeners()` untuk `eloquent.*`.

### 6.4 Validation, Resources, Policies, Jobs, Events, Schedule, Commands

- **FormRequest**: `app()->make($class)` dengan `Request::create('/', 'POST')` + `setUserResolver` (user dummy bertipe `Authenticatable` → `#[Daragic\AsUser(User::class)]` bila `rules()` bergantung user) → panggil `rules()`, `messages()`, `attributes()`; `authorize()` dan `prepareForValidation()` via AST. Bila `rules()` melempar karena bergantung `$this->route('x')`, ulangi dengan parameter rute dummy; bila masih gagal → AST (parse array literal) + TODO.
- **Resource**: AST `toArray()` → Dialect (ekspresi `$this->when/whenLoaded/mergeWhen/whenCounted/whenHas` dipetakan ke API resource Daravel), `with()`, `$wrap`, `withoutWrapping()` global via AST provider.
- **Policies/Gates**: `Gate::policies()` (model → policy) + refleksi metode publik policy + `before`; `Gate::abilities()` closure → AST; `Gate::guessPolicyNamesUsing` dicatat.
- **Jobs**: pemindaian classmap `ShouldQueue` + refleksi konstruktor/properti (tipe PHP + docblock), `$tries/$backoff/$timeout/$maxExceptions/$queue/$connection/$deleteWhenMissingModels`, `uniqueId()/uniqueFor`, `middleware()` (`RateLimited`, `WithoutOverlapping`, `ThrottlesExceptions`, `SkipIfBatchCancelled`), `retryUntil()`, `handle()`/`failed()` → AST. Properti bertipe `Model` → `ModelRef` di DAM (paritas `SerializesModels`).
- **Events/Listeners**: `Event::getRawListeners()` (nama event → listener `Class@method` / closure); `ShouldQueue` pada listener; subscriber `subscribe()` via AST; `ShouldBroadcast` + `broadcastOn()` (T2).
- **Schedule**: `app(Schedule::class)->events()` → `Event`: `expression`, `command` (string artisan / closure `description`), `timezone`, `withoutOverlapping`/`expiresAfter`, `onOneServer`, `runInBackground`, `evenInMaintenanceMode`, `environments`, hook closures (`before/after/onSuccess/onFailure` → AST), `mutexName()`.
- **Commands**: `Artisan::all()` → kelas aplikasi: `signature`, `description`, `handle()` AST, opsi/argumen hasil parse signature.

### 6.5 Config & Env

- `config()->all()` setelah boot sandbox memberi nilai efektif, tetapi nilai yang berasal dari `env()` harus dikembalikan ke **kunci env**: AST file `config/*.php` dipindai untuk `env('KEY', default)` dan posisinya dalam array (path `database.connections.mysql.host`) → DAM `{"$env": "DB_HOST", "default": "127.0.0.1"}`. Closure/objek dalam config → `{"$source": ...}`.
- `.env.example` diparse untuk daftar kunci; nilai **tidak** diekspor dari `.env` nyata (D9). Tipe env diinferensi dari default & penggunaan (`(bool) env()`, `(int) env()`).
- Config kustom aplikasi (`config/inventaris.php`) dipertahankan utuh → Daravel mode mekanis (ADR-021) + kelas bertipe hasil generate.

### 6.6 Migrasi & Skema

- **Recording Blueprint** (utama): sandbox memasang `Schema::blueprintResolver(fn ($conn, $table, $callback, $prefix) => new RecordingBlueprint(...))` lalu menjalankan setiap migrasi `up()` terhadap koneksi **perekam** yang tidak mengeksekusi SQL (`DB::pretend` + grammar dummy). `RecordingBlueprint` mencatat panggilan kolom/indeks/FK terstruktur (`$table->string('sku', 32)->unique()`) → operasi DAM. `down()` direkam dengan cara sama. `DB::statement('...')` di dalam migrasi direkam sebagai `raw` dengan dialek asal; `daragic` mencoba mengklasifikasi raw SQL sederhana (`ALTER TABLE ... ADD INDEX`) dan menandai sisanya TODO dengan peringatan dialek.
- **Fallback AST** untuk migrasi yang bergantung pada data/kondisi runtime (`if (Schema::hasColumn(...))`) → kondisi dipertahankan sebagai Dialect.
- **Skema aktual** (bila `--db`): Laravel 11+ `Schema::getTables()/getColumns()/getIndexes()/getForeignKeys()/getViews()`; Laravel 10: `doctrine/dbal` bila terpasang, selain itu dilewati dengan catatan. Dipakai untuk `schema:diff` (Bagian 15) dan untuk `model:sync` accessor.
- Tabel `migrations` (nama + batch) diekspor agar Daravel dapat **melanjutkan** batch (koeksistensi).

### 6.7 Views, Lang, Tests, Packages

- Blade: parser `daragic` sendiri (subset gelombang 1–2, Bagian 13) menghasilkan AST + laporan direktif tak didukung per file; file `.blade.php` disalin apa adanya ke DAM (`views/`).
- Lang: `lang/*/**.php` dievaluasi (`require`) → JSON; `lang/*.json` disalin; placeholder `:attribute` dan pluralisasi `|` dipertahankan.
- Tests: PHPUnit/Pest di `tests/Feature|Unit` → AST → Dialect khusus test (Bagian 14).
- Packages: `composer.lock` → nama, versi, lisensi; provider dari `extra.laravel.providers`; publishes via `ServiceProvider::pathsToPublish()`; klasifikasi tier via `equivalence.yaml` + heuristik (ekstensi C/FFI, Livewire → C).

### 6.8 PHPStan Type Dump

Ekstensi `daragic/phpstan-types` mendaftarkan *collector* PHPStan yang, untuk setiap ekspresi yang relevan (variabel, properti, hasil pemanggilan, parameter, return), menulis `types.json`: `{file, line, col, exprHash, type: "array<int, App\\Models\\Post>"}`. Transpiler memakainya sebagai sumber tipe prioritas tertinggi. Tanpa PHPStan, inferensi lokal (Bagian 8.4) dipakai dan skor kesiapan menurun (dilaporkan sebagai saran "jalankan PHPStan level ≥ 6").

### 6.9 Version Gating

| Fitur | L10 | L11 | L12 |
| :-- | :-- | :-- | :-- |
| `Schema::getColumns()` dkk | dbal | ✓ | ✓ |
| `#[ObservedBy]`, `casts()` metode | 10.44+ | ✓ | ✓ |
| Middleware di `bootstrap/app.php` | ✗ (Kernel) | ✓ | ✓ |
| `Event::getRawListeners()` | ✓ | ✓ | ✓ |
| `Http::preventStrayRequests()` | ✓ | ✓ | ✓ |
| `Route::getRoutes()` + `bindingFields()` | ✓ | ✓ | ✓ |

---

## 7. Extractor Daravel (sisi Dart)

Karena Daravel dirancang introspeksibel (V2 ADR-002, ADR-011, 7.10.8), extractor Daravel hampir seluruhnya runtime:

- `dartisan daragic:export [--to-laravel] [--out=dam/]` mem-boot aplikasi (tanpa `serve`), lalu membaca `router.routes` (metode, path, nama, middleware, constraints, binding, metadata OpenAPI), `ModelRegistry` (`ModelDefinition<T>`: tabel, key, fillable, casts, hidden, relasi objek, scopes, observers), `Gate` (policies & abilities), `JobRegistry`, `EventRegistry` (listener, queued), `Schedule`, `ConfigRepository` (pohon dot-notation + peta env dari `Env` accessor log), registry migrasi (operasi `Blueprint` direkam dengan `SchemaBuilder` mode `pretend`), seeder/factory registry, `MiddlewareRegistry` (alias, grup, global).
- Badan metode (controller, policy, job `handle`, listener, scope, accessor, resource `toArray`, command `handle`, migrasi non-trivial) diekstrak dengan `package:analyzer` (resolved AST + tipe statis Dart → Dialect IR dengan tipe yang **sudah pasti**).
- Validasi: objek `Rule` → bentuk terstruktur DAM (introspeksi `name`/`args`) **dan** DSL (serialisasi balik `Rule.toDsl()`), sehingga emitter PHP dapat menulis string Laravel idiomatis.
- Views: `resources/views/**/*.blade.php` disalin (sumber kebenaran tetap Blade); kode Dart hasil `view:compile` **tidak** diekspor.
- Tests: `test/feature/**` memakai `TestClient` → AST → Dialect test → PHPUnit/Pest.
- Keluaran DAM identik strukturnya dengan ekspor Laravel; `meta.source.framework = daravel`.

---

## 8. Dialect IR & Transpiler

### 8.1 Pipeline

```text
PHP source ──(nikic/php-parser)──▶ PHP AST ──(resolve names, PHPStan types)──▶ Typed PHP AST
   ──(lowering)──▶ Dialect IR ──(normalize: async marks, array semantics, helpers)──▶ Normalized IR
   ──(Dart codegen)──▶ Dart source ──(dart format)──▶ file + laporan cakupan
Dart source ──(package:analyzer, resolved)──▶ Dart AST ──(lowering)──▶ Dialect IR ──(PHP codegen)──▶ PHP source ──(php-cs-fixer)──▶ file
```

Dialect IR adalah AST ekspresi/pernyataan bahasa-netral: `Block, If, Switch(strict|loose), For, ForEach(keyVar?, valueVar, byRef?), While, DoWhile, Try(catches[type, var], finally), Return, Throw, Assign(op), Binary(op, loose?), Unary, Call(callee: Static|Method|Function|Closure, args named/positional, spread), New, Closure(params, captures, async?), Literal(int|float|string|bool|null), Interp(parts), ArrayLit(entries: positional|keyed, spread), Index, Prop, NullSafeProp, Ternary, Coalesce, Match, Instanceof, Cast(type), Lambda, Yield, ListDestructure, Opaque(lang, text, reason)`. Tipe pada node: `TypeRef(kind: int|float|string|bool|null|array<K,V>|list<T>|map<K,V>|object<FQCN>|union|mixed|callable, nullable)`.

### 8.2 Cakupan Dialect (gelombang 1 = D1, gelombang 2 = D3)

**Pernyataan & ekspresi PHP** gelombang 1: semua di 8.1 kecuali `Yield` (gelombang 2), `goto` (tidak pernah), `declare`, `global`, `static` var lokal (gelombang 2 → closure state), referensi `&` hanya pada `foreach (... as &$v)` sederhana dan parameter by-ref yang dapat ditulis ulang menjadi nilai kembali (selain itu TODO).

**Kelas**: `class/abstract/final/readonly`, `interface` → `abstract interface class`, `trait` tanpa `__call/__get` dan tanpa properti statik bersama → `mixin`, `enum` (backed & pure, metode, `cases()`), konstruktor promosi → initializing formals, `static` metode/properti, konstanta kelas, `__construct` DI → parameter + resolusi `app.make<T>()` di titik `new` bila tipe terdaftar di container, `__toString` → `toString()`, `JsonSerializable` → `toJson()`, `ArrayAccess/Countable/IteratorAggregate` → `operator []`, `length`, `Iterable`, `Stringable`, `__invoke` → `call()`, `__get/__set/__call` **hanya** untuk Eloquent (sudah dimodelkan) — kustom → TODO.

**Pustaka standar PHP** (tabel pemetaan ±350 fungsi di `parity.phpStdlib`): string (`str_*`, `substr`, `strlen`, `mb_*`, `sprintf`, `number_format`, `trim`, `explode/implode`, `preg_*`, `ucfirst`, `strtolower`), array (`array_*`, `count`, `in_array`, `sort/usort/ksort`, `array_map/filter/reduce`, `compact/extract`(extract → TODO), `range`), matematika (`abs, round, floor, ceil, intdiv, max, min, pow, sqrt, rand/random_int`), tanggal (`date, time, strtotime` → `DateTime` + peringatan format), JSON (`json_encode/decode` + flags yang didukung), hashing (`hash, md5, sha1, hash_hmac, password_hash/verify` → `Hash`), `filter_var` (validator subset), `is_*` (`is_null/is_array/is_string/is_numeric`), `intval/floatval/strval/boolval`, `var_dump/print_r/dd` → `dump()`, `sleep/usleep` → `await Future.delayed`, `uniqid` → `Str.random`, `base64_*`, `urlencode/rawurlencode/http_build_query`, `parse_url`, `file_get_contents` lokal → `File`, `env/config/app/route/url/abort/response/redirect/view/collect/now/old/session/cache/auth/request/logger/report/rescue/retry/tap/value/with/optional/blank/filled/str/throw_if/throw_unless/once/dispatch/event/broadcast` (helper Laravel; `optional` → `?.`, `with` → `tap`).

**Laravel API**: seluruh simbol di `parity.yaml` (Eloquent builder & model, Query builder, `Collection` & `LazyCollection` (subset), `Str`, `Arr`, `Carbon` (subset ±80 metode), `Request`, `Response`, `Validator`, `Auth`, `Gate`, `Cache`, `Queue`, `Bus`, `Event`, `Log`, `Storage`, `Http` (T2), `Mail` (T2), `DB`, `Schema`, `Hash`, `Crypt`, `URL`, `Route`, `Config`, `App`, `Lang`, `View` (T2), exceptions, `JsonResource`, `Paginator`).

### 8.3 Pemetaan Async (algoritma)

Dart I/O adalah `Future`; PHP sinkron. Transpiler harus menyisipkan `await`/`async` secara benar dan **mempertahankan urutan eksekusi sekuensial PHP**:

1. Tandai node pemanggilan sebagai `async` bila simbol target di `parity.yaml` memiliki `async: true` (semua I/O: DB, cache, queue, storage, hash, http).
2. **Propagasi whole-project**: fungsi/metode yang mengandung node async menjadi `async` dengan return `Future<T>`; setiap situs pemanggilan ke fungsi itu menjadi async; iterasi hingga titik tetap (fixpoint) atas graf pemanggilan proyek (dinamis via interface: bila satu implementasi async, metode interface menjadi `Future<T>` dan semua implementasi dibungkus).
3. **Closure dalam API koleksi/builder**: `->map(fn)` dengan body async → `await Collection.mapAsync(fn)` (sekuensial, mempertahankan urutan dan semantik efek samping); `->each`, `->filter`, `->reduce`, `->sortBy`, `array_map`, `usort` memiliki padanan `*Async`; closure async di `usort` → TODO (komparator async tidak masuk akal).
4. Ekspresi dengan beberapa pemanggilan async dievaluasi **kiri-ke-kanan** seperti PHP (Dart `await a() + await b()` sudah kiri-ke-kanan).
5. Konstruktor tidak boleh async → inisialisasi I/O di konstruktor PHP dipindah ke metode `init()` + TODO peringatan.
6. Getter/`__get` async (akses relasi lazy `$user->posts`): PHP lazy-load di akses properti; Dart `user.posts` adalah getter sinkron atas relasi **termuat**; transpiler mengubah akses relasi yang **belum dijamin termuat** menjadi `await user.loadRelation<List<Post>>('posts')` **dan** menyarankan `with()` di query asal (laporan "lazy loading terdeteksi"). Bila `with([...])` terlihat di rantai query yang sama (analisis aliran sederhana), akses tetap sinkron.
7. Exception: `catch` tetap berlaku untuk error yang dilempar dari `await`.

### 8.4 Inferensi Tipe

Prioritas: (1) `types.json` PHPStan; (2) atribut `#[Daragic\Type]`; (3) deklarasi PHP (tipe parameter/return/properti, termasuk union & nullable); (4) docblock `@var/@param/@return` (PHPStan syntax); (5) inferensi lokal berbasis aliran: literal, hasil pemanggilan terpetakan (parity memberi tipe kembali, mis. `User::find()` → `User?`, `->get()` → `ModelCollection<User>`, `->paginate()` → `Paginator<User>`, `$request->input()` → `Object?`), operator (`.` → String, aritmetika → num), `foreach` elemen dari tipe koleksi; (6) fallback `Object?`/`dynamic` dengan TODO "tipe tidak diketahui" dan **mode faithful memakai helper dinamis** (`php.get(x, 'key')`).

Array PHP → Dart: `list<T>` → `List<T>`; `array<string,T>` → `Map<String,T>`; `array<int,T>` dengan kunci berurutan → `List<T>`, tidak berurutan → `Map<int,T>`; `array{a:int,b:string}` (shape) → **record** `({int a, String b})` bila lokal, atau kelas data bila melintasi batas fungsi (`--shapes=records|classes|maps`; default otomatis per ADR-D03: record untuk shape lokal, kelas data untuk shape di batas publik); `mixed[]` → `List<Object?>`. Bukti kunci berurutan: literal tanpa kunci, `$a[] = ...`, hasil fungsi yang mengembalikan list (`array_values`, `explode`, `range`).

### 8.5 Tabel Perbedaan Semantik PHP → Dart (dan cara `faithful` menanganinya)

| Topik | PHP | Dart | Mode `faithful` | Mode `idiomatic` (jika tipe membuktikan aman) |
| :-- | :-- | :-- | :-- | :-- |
| Kebenaran `if ($x)` | `"0"`, `""`, `0`, `0.0`, `[]`, `null` false | hanya `bool` | `if (truthy(x))` | `if (x)` bila `bool`; `x.isNotEmpty` bila String/List; `x != null` bila nullable |
| `==` longgar | juggling (`"1" == 1`, `null == false`) | tipe ketat | `looseEquals(a, b)` (menerapkan aturan PHP 8) | `a == b` bila tipe sama |
| `empty($x)` | `"0"` dianggap kosong | — | `phpEmpty(x)` (**bukan** `blank()`, yang berbeda untuk `"0"`) | `x == null \|\| x.isEmpty` |
| `isset($a['k'])` | ada **dan** non-null | — | `a.containsKey('k') && a['k'] != null` → helper `isset(a, 'k')` | sama |
| Array = nilai (copy on assign/pass) | salinan | referensi | Analisis aliran: bila sumber dimutasi setelah di-assign/dilewatkan, sisipkan `List.of/Map.of` di titik assign/pass (konservatif: copy bila ragu) | copy hanya bila terbukti perlu |
| `strlen`/`substr`/`strpos` byte | byte UTF-8 | code unit UTF-16 | `phpStrlen(s)` (`utf8.encode(s).length`), `phpSubstr` (byte-aware) ; `mb_*` → `runes`-based | `s.length` bila ASCII terbukti (konstanta) |
| `/` | int/int → int bila habis, selain itu float | selalu `double` | `phpDiv(a, b)` mengembalikan `num` sesuai aturan PHP; `intdiv` → `~/`; `%` → `%` (tanda ikut dividend, sama) | `a / b` atau `a ~/ b` bila tipe/konteks jelas |
| Overflow int | → float | wrap 64-bit | `phpAdd/mul` dengan cek overflow → `double` | aritmetika biasa bila range terbukti |
| `null` dalam aritmetika/`.` | `null` → 0/"" (+ warning) | error | `phpNum(x)`, `phpStr(x)` | `x ?? 0` |
| Perbandingan string numerik `"10" < "9"` | numerik → false | leksikografis → true | `phpCompare(a, b)` untuk `<,>,<=,>=,<=>` pada tipe non-num | `compareTo` bila tipe num/String murni |
| `switch` | longgar | ketat | `switch` + `looseEquals` dalam `if-else chain` bila tipe campur | `switch` biasa |
| `match` tanpa kecocokan | `UnhandledMatchError` | harus exhaustive | tambahkan `_ => throw UnhandledMatchError(v)` | sama |
| Carbon mutable (`$d->addDay()`) | mutasi di tempat | `DateTime` immutable | `d = d.addDays(1)` + peringatan jika objek dibagikan (alias) | sama |
| `round()` | half away from zero | sama (`num.round`) | `phpRound(x, precision)` untuk presisi > 0 | `round` |
| `sort()` dkk | mengubah array di tempat, flag | `sort()` di tempat | `phpSort(list, flags)` | `list.sort()` |
| `array_merge` kunci numerik | renumber | — | `phpArrayMerge` | `[...a, ...b]` untuk list |
| `foreach` by value pada objek | referensi objek | sama | — | — |
| Regex PCRE | `preg_*`, flag `/i`, `(?P<n>)`, possessive `*+`, `\A \z \Z`, `(*UTF8)` | `RegExp` ECMAScript-like | Penerjemah regex: `(?P<n>)`→`(?<n>)`, `\A`→`^` (tanpa multiline), `\z`→`$`, flag `i/m/s/u/x` dipetakan, possessive/atomic/`\K`/conditional → TODO; regex **diuji saat generate** (`RegExp` kompilasi) | sama |
| `json_encode` | flags (`JSON_PRETTY_PRINT`, `UNESCAPED_*`), `JSON_THROW_ON_ERROR` | `jsonEncode` | `phpJsonEncode(v, flags)` | `jsonEncode` |
| Float ke string | `0.1 + 0.2` → `"0.3"` (precision 14) | `"0.30000000000000004"` | `phpStr(double)` meniru `precision=14`/`serialize_precision=-1` | `toString()` |
| Integer key string `"1"` → `1` di array | normalisasi | tidak | `phpArrayKey(k)` saat kunci dinamis | — |
| `static::` late static binding | per subclass | tidak ada static inheritance | generator mengemit metode statik per subclass (seperti model) atau TODO | — |
| Exception standar | `TypeError`, `ValueError`, `DivisionByZeroError`, `ErrorException` | `TypeError`, `ArgumentError`, `UnsupportedError`, `IntegerDivisionByZeroException` | pemetaan di `parity.exceptions` | — |

Semua helper `php_compat` diuji **secara diferensial** terhadap PHP nyata di CI (Bagian 19.3) sehingga semantiknya terbukti, bukan diasumsikan.

### 8.6 Gaya Keluaran & `modernize`

`--style=faithful` (default) memaksimalkan kesetiaan semantik dengan helper; `--style=idiomatic` memakai idiom Dart di mana tipe membuktikan aman. `dartisan daragic:modernize [--dry-run]` adalah pass terpisah yang mengganti helper dengan idiom bila aman (analyzer resolved types) dan melaporkan jumlah helper tersisa sebagai metrik "utang kompatibilitas". Lint `daravel_lints` menandai pemakaian helper `php_compat` di kode baru (bukan hasil generate) sebagai peringatan.

### 8.7 Jaminan Keluaran

1. Setiap file hasil generate lolos `dart analyze` tanpa error (diuji di CI tool atas korpus; kegagalan = bug tool, bukan tugas pengguna).
2. Setiap `DARAGIC-TODO` memiliki: alasan terklasifikasi (`unsupported-construct`, `unknown-type`, `dynamic-feature`, `semantic-risk`, `package-tier-c`), cuplikan sumber PHP, dan tautan dokumentasi solusi.
3. Komentar `// daragic: <php file>:<line>` pada setiap pernyataan hasil terjemahan (dapat dimatikan `--no-source-map`) agar review mudah dan laporan dapat menghitung cakupan per baris.
4. Nama variabel/fungsi dikonversi ke konvensi Dart (`$user_name` → `userName`) secara konsisten dengan peta nama yang disimpan (untuk arah balik).

---

## 9. Emitter Dart

### 9.1 Reuse Generator Resmi

Emitter **tidak** menulis file dari nol; ia memanggil API pustaka `dartisan_cli` (`Scaffolder`) yang juga dipakai `dartisan make:*`: `scaffolder.model(ModelSpec)`, `.migration(MigrationSpec)`, `.controller(ControllerSpec)`, `.request(RequestSpec)`, `.resource`, `.policy`, `.job`, `.listener`, `.event`, `.observer`, `.command`, `.seeder`, `.factory`, `.middleware`, `.rule`, `.test`. Badan metode yang berasal dari Dialect disisipkan ke slot `body` setiap spec; bila kosong, stub standar dipakai. Keuntungan: proyek hasil migrasi **tidak dapat dibedakan** dari proyek yang dibuat manusia dengan `dartisan`, dan perbaikan stub otomatis berlaku untuk keduanya.

### 9.2 Pemetaan Path Deterministik (ADR-022)

| Laravel | Daravel |
| :-- | :-- |
| `app/Http/Controllers/Api/V1/UserController.php` | `lib/app/http/controllers/api/v1/user_controller.dart` (`UserController`) |
| `app/Models/User.php` | `lib/app/models/user.dart` |
| `app/Http/Requests/StoreUserRequest.php` | `lib/app/http/requests/store_user_request.dart` |
| `app/Http/Resources/UserResource.php` | `lib/app/http/resources/user_resource.dart` |
| `app/Policies/UserPolicy.php` | `lib/app/policies/user_policy.dart` |
| `app/Jobs/*`, `app/Events/*`, `app/Listeners/*`, `app/Observers/*`, `app/Rules/*`, `app/Console/Commands/*`, `app/Services/*`, `app/Support/*` | `lib/app/{jobs,events,listeners,observers,rules,console/commands,services,support}/*` |
| `database/migrations/2024_01_01_000000_create_users_table.php` | `database/migrations/m_2024_01_01_000000_create_users_table.dart` (`CreateUsersTable`) |
| `database/seeders/*`, `database/factories/*` | `database/{seeders,factories}/*` |
| `routes/api.php`, `routes/web.php`, `routes/console.php` | `routes/api.dart`, `routes/web.dart`, `routes/console.dart` |
| `config/*.php` | `config/*.dart` (map mekanis) + `config/typed/*.dart` (kelas bertipe) |
| `resources/views/**.blade.php` | `resources/views/**.blade.php` (sama; kompilasi ke `lib/generated/views/**.dart`) |
| `lang/**` | `lang/**` (`.dart` map + `.json`) |
| `tests/Feature/*Test.php` | `test/feature/*_test.dart` |
| `bootstrap/app.php`, `app/Providers/*` | `bootstrap/app.dart`, `lib/app/providers/*` + registry files |

Namespace PHP → path Dart: `App\` → `lib/app/`, PascalCase → snake_case; `Illuminate\…` tidak pernah muncul (dipetakan ke `package:daravel`). Peta ini disimpan di `daragic.lock` dan **dibalik** oleh emitter PHP.

### 9.3 Region Marker & Kepemilikan

Setiap file hasil generate memiliki header `// GENERATED BY daragic from <php path> (hash) — edit freely; regions marked <daragic:...> are regenerated on re-import`. Region yang **boleh** diregenerasi: `<daragic:definition>` (ModelDefinition), `<daragic:statics>`, `<daragic:accessors>`, `<daragic:rules>`, `<daragic:routes>`, `<daragic:schema>` (migrasi). Badan metode bisnis berada **di luar** region: setelah import pertama, badan metode menjadi milik manusia.

### 9.4 Import Inkremental & Merge Tiga-Arah

- `daragic.lock` menyimpan per entitas: hash DAM, hash hasil generate (base), path file.
- Pada `--merge`: untuk setiap file, tiga versi — **base** (hasil generate sebelumnya, disimpan di `.daragic/base/`), **ours** (file pengguna saat ini), **theirs** (hasil generate baru) — digabung dengan algoritma diff3 pada level baris; region marker digabung pada level region (theirs menang di region, ours menang di luar region); konflik ditulis dengan penanda `<<<<<<< daragic` dan dilaporkan; tidak ada file ditimpa tanpa penanda.
- Entitas yang dihapus di Laravel → file Dart ditandai `@Deprecated('removed upstream')` dan dilaporkan, **tidak dihapus** otomatis (`--prune` untuk menghapus).
- Perubahan nama (rename kelas) dideteksi lewat kemiripan isi (hash badan metode) → ditawarkan sebagai rename, bukan delete+create.

### 9.5 Kualitas Keluaran

`dart format` + `dart fix --apply` + `dart analyze` dijalankan oleh emitter; import diurutkan; doc comment PHP (`/** */`) dipindahkan sebagai `///`; atribut PHP yang bukan `Daragic` dipindahkan sebagai komentar `// php-attribute: ...`.

---

## 10. Emitter PHP (arah Daravel → Laravel)

> **Catatan (ADR-D01):** emitter struktural + test dibangun di D2; emitter badan metode (D3) diputuskan setelah D2 berdasarkan permintaan pengguna. DAM, Dialect IR, dan `parity.yaml` tetap simetris sejak D0 agar D3 tidak memerlukan redesain.

- Memakai `php artisan make:*` yang di-*replay* pada proyek Laravel scratch (`laravel new` atau proyek target `--into`), lalu mengisi badan dari Dialect IR → PHP codegen (PHP 8.2+, `declare(strict_types=1)` opsional `--strict-types`, `readonly`, enum, named args, promoted constructor).
- `ModelDefinition<T>` → kelas Eloquent dengan `$table/$fillable/$casts/$hidden`, `casts()` metode (L11+), relasi sebagai metode bertipe return, scopes `scopeXxx`, `#[ObservedBy]`.
- `Rule` objek → DSL string bila semua aturan memiliki bentuk string; selain itu `Rule::` objek (`Rule::unique(...)->ignore(...)`, `Rule::enum(...)`, `Password::min(8)->letters()`).
| Dart khusus | PHP |
| :-- | :-- |
| `Future<T>`/`await` | sinkron (dihapus) |
| records `(int, String)` | array shape `array{0:int,1:string}` + docblock |
| `sealed` + `switch` exhaustive | `match` + `default => throw` |
| extension methods | helper statik `Support\Ext::fn($x)` |
| `Isolate.run` | dijalankan sinkron + TODO "pertimbangkan queue" |
| `int` 64-bit | `int` PHP 64-bit (sama di platform 64-bit) |
| `Stream` SSE/WS | TODO (Laravel: `response()->stream`, Reverb) |
- Blade: disalin apa adanya. Test: `TestClient` → PHPUnit (`$this->getJson()`) atau Pest (`--pest`).
- Round-trip test (Bagian 19): Laravel → DAM → Daravel → DAM → Laravel harus menghasilkan rute, skema, aturan validasi, dan policy **identik**; badan metode boleh berbeda secara tekstual tetapi test harus tetap hijau.

---

## 11. `parity.yaml` — Spesifikasi & Tata Kelola

### 11.1 Struktur

```yaml
parityVersion: "12.1"          # laravel major.minor yang dipetakan
targets: { laravel: "^12.0", daravel: "^1.0" }
symbols:
  - id: request.validate
    php:  { fqcn: Illuminate\Http\Request, member: validate, kind: method, signature: "validate(array $rules, array $messages = [], array $attributes = []): array" }
    dart: { library: "package:daravel/http.dart", member: Request.validate, signature: "Future<ValidatedData> validate(Map<String, List<Rule>> rules, {Map<String,String>? messages, Map<String,String>? attributes})" }
    async: true
    args: { rules: { transform: rulesMapFromPhp } }      # transformasi argumen bernama (fungsi di codegen)
    returns: { php: "array", dart: "ValidatedData", note: "akses via data.string('x') atau data['x']" }
    semantics: identical        # identical | equivalent | differs
    differs: null
    since: { laravel: "5.5", daravel: "0.4" }
    tests: [corpus/parity/request_validate_test.php]
  - id: builder.firstOrFail
    php:  { fqcn: Illuminate\Database\Eloquent\Builder, member: firstOrFail }
    dart: { member: ModelQuery.firstOrFail }
    async: true
    throws: { php: ModelNotFoundException, dart: ModelNotFoundException }
    semantics: identical
  - id: carbon.diffForHumans
    php:  { fqcn: Carbon\Carbon, member: diffForHumans }
    dart: { member: "DateTimeX.diffForHumans" }
    semantics: equivalent
    differs: "lokal: Daravel mendukung en/id pada 1.0; Carbon mendukung 100+ lokal"
helpers:  { map: { env: env, config: config, route: route, abort: abort, collect: "Collection.of", optional: "?.", with: tap }, missing: [] }
middlewareAliases: { auth: auth, "auth:sanctum": "auth:token", throttle: throttle, can: can, signed: signed, "cache.headers": cacheHeaders }
exceptions: { Illuminate\Database\Eloquent\ModelNotFoundException: ModelNotFoundException, Illuminate\Auth\Access\AuthorizationException: AuthorizationException, Illuminate\Validation\ValidationException: ValidationException, Symfony\Component\HttpKernel\Exception\NotFoundHttpException: NotFoundHttpException }
phpStdlib:
  - { php: strlen, dart: phpStrlen, idiomatic: ".length", when: "ascii-proven" }
  - { php: array_map, dart: ".map(...).toList()", asyncVariant: "Collection.mapAsync" }
validationRules: { required: required, email: email, "unique": "unique", "exists": "exists", "password": "password", "enum": "enumValues" }
casts: { "datetime": dateTime, "array": json, "json": json, "encrypted": encrypted, "decimal:2": "decimal(2)", "AsArrayObject": json }
```

### 11.2 Tata Kelola

- `parity.yaml` hidup di repo `daravel/parity`, **berversi per pasangan rilis** (`laravel-12.1/daravel-1.0`). Rilis Laravel baru → branch paritas baru; `daragic` memilih paritas berdasarkan versi Laravel yang diekstrak dan versi Daravel target.
- **Test arsitektur Daravel** (`parity_test.dart`) memverifikasi setiap `dart.member` benar-benar ada dengan tanda tangan yang kompatibel (introspeksi via `package:analyzer` atas `package:daravel`). Framework **tidak boleh** mengubah API yang terdaftar tanpa memperbarui paritas (CI gagal).
- **Test paritas semantik**: setiap simbol `semantics: identical` memiliki minimal satu kasus di korpus golden yang dieksekusi di PHP dan Dart dengan hasil dibandingkan.
- Dokumentasi side-by-side dibangkitkan (`daragic docs:parity`) → halaman per domain (Routing, Eloquent, Validation…) dengan kolom Laravel/Daravel dan badge `identical/equivalent/differs`.
- Kontribusi komunitas: PR ke `parity.yaml` wajib menyertakan kasus korpus.

---

## 12. Anotasi (Petunjuk Pengguna)

### 12.1 PHP — `daravel/daragic-attributes`

| Atribut | Target | Efek |
| :-- | :-- | :-- |
| `#[Daragic\Type('List<Map<String,int>>')]` | properti, parameter, return, variabel (via komentar `/** @daragic-type */` untuk lokal) | Menimpa inferensi tipe |
| `#[Daragic\Skip(reason: '...')]` | kelas, metode | Tidak dikonversi; stub + TODO dengan alasan |
| `#[Daragic\Replace(dart: 'return Response.noContent();')]` | metode | Badan Dart literal menggantikan transpilasi |
| `#[Daragic\Model(keyType: 'uuid', table: 'x', connection: 'y')]` | kelas model | Menimpa introspeksi |
| `#[Daragic\Relation(type: 'hasManyThrough', related: Post::class, through: Author::class, keys: [...])]` | metode relasi | Untuk relasi yang gagal diinferensi (mis. relasi kondisional) |
| `#[Daragic\Json]` / `#[Daragic\ListOf(User::class)]` / `#[Daragic\MapOf('string', 'int')]` | properti/param | Bentuk array |
| `#[Daragic\Equivalent(dart: 'package:excel/excel.dart', adapter: 'ExcelAdapter')]` | `use` import/kelas | Pemetaan package pihak ketiga lokal (menimpa `equivalence.yaml`) |
| `#[Daragic\AsUser(User::class)]` | FormRequest/Policy | User dummy saat ekstraksi |
| `#[Daragic\Async]` / `#[Daragic\Sync]` | metode | Memaksa keputusan async |
| `#[Daragic\Faithful]` / `#[Daragic\Idiomatic]` | kelas/metode | Gaya per unit |
| `#[Daragic\Dialect('mysql')]` | migrasi raw SQL | Menandai dialek SQL raw |
| `#[Daragic\Tier('B')]` | kelas package | Klasifikasi manual |

Docblock PHPStan/Psalm (`@var`, `@param`, `@return`, `array<K,V>`, `list<T>`, `array{...}`) dihormati tanpa atribut. `daragic analyze` **menyarankan** atribut/docblock tepat pada lokasi yang menurunkan skor.

### 12.2 Dart — `package:daragic/annotations.dart`

`@laragic.Type('array<string,int>')`, `@laragic.Skip()`, `@laragic.Replace(php: '...')`, `@laragic.Sync()`, `@laragic.Pest()` (gaya test), `@laragic.Equivalent(composer: 'spatie/laravel-permission')`. Semua `const` dan tanpa efek runtime (tree-shaken di AOT).

### 12.3 Prinsip

Anotasi **tidak pernah wajib** dan tidak mengubah perilaku aplikasi; keduanya hanya mengarahkan generator. Anotasi dipertahankan saat round-trip (disimpan di DAM `hints`).

---

## 13. Kompiler Blade (`daravel_blade`)

### 13.1 Posisi

Blade adalah bahasa template Daravel (ADR-018). `.blade.php` di `resources/views` adalah sumber kebenaran di **kedua** framework; Daravel mengompilasinya ke Dart (`lib/generated/views/<path>.view.dart`) pada `dartisan view:compile`, otomatis saat `make`/`import`/hot reload. Runtime AOT hanya memuat fungsi Dart hasil kompilasi — tidak ada parser template di produksi, tidak ada `eval`.

### 13.2 Pipeline

`Blade source` → lexer (teks, `{{ }}`, `{!! !!}`, `{{-- --}}`, `@directive(args)`, `<x-component>`) → parser (AST: `Text, Echo(escaped), RawEcho, If/ElseIf/Else, Unless, Isset, Empty, ForEach/ForElse (+ `$loop`), For, While, Switch, Include(name, data), IncludeWhen/Unless/If/First, Extends, Section/Yield/Parent/Show/Stop, Push/Stack/Prepend, Once, Component(name, attrs, slots), Props, Auth/Guest/Can/Cannot/Canany, Csrf, Method, Json, Error, Env/Production, Verbatim, Php(block), Inject, Vite, Class/Style, Checked/Selected/Disabled/Readonly/Required, Lang/Choice (T2), Livewire(unsupported))` → **ekspresi di dalam direktif/echo adalah PHP** → di-lower ke Dialect IR → Dart.

### 13.3 Semantik yang Dijaga

- Escaping `{{ }}` identik `e()` Laravel: `htmlspecialchars(ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8', double_encode=true)` → implementasi Dart `bladeEscape()` diuji diferensial. Nilai `Htmlable` (`toHtml()`) tidak di-escape.
- `$loop` (`index, iteration, remaining, count, first, last, even, odd, depth, parent`) disediakan objek `Loop` Dart.
- Layout: `@extends/@section/@yield/@parent` dikompilasi menjadi komposisi fungsi: view anak menghasilkan `Map<String, Section>` lalu memanggil layout; `@push/@stack` menjadi akumulasi terurut.
- Komponen class-based `<x-alert type="error" :message="$m">` → kelas Dart `AlertComponent` (dari `app/View/Components/Alert.php` via transpiler) dengan `render()`; anonymous component → view fungsi dengan `@props`; slot bernama `<x-slot:title>` → parameter `slots`.
- Data view: `View.make('users.index', {'users': users})` → fungsi hasil kompilasi menerima `Map<String, Object?>` (mode faithful: akses dinamis `data['users']`) atau **kelas data bertipe** per view bila `@props`/`#[Daragic\ViewData]` tersedia (mode idiomatic).
- `@php ... @endphp` → Dialect (sering sederhana: assignment); tidak didukung → TODO yang me-render komentar HTML `<!-- DARAGIC-TODO -->` di dev dan dicatat di laporan.
- `@include` dinamis (`@include($name)`) → registry view bernama (semua view terkompilasi terdaftar di `ViewRegistry` → lookup runtime tanpa parser).
- `@vite`/`@asset` → helper aset Daravel (manifest Vite dibaca saat boot).
- `@csrf`, `@method`, `@error`, `@old`, `session()` → tersedia setelah Session (Tier 2) — kompiler mengemit panggilan ke API Daravel yang sama.
- **Tidak didukung**: `@livewire`, `@inject` ke layanan yang bergantung PHP-dinamis (hanya `@inject` ke kelas terkonversi), `@php` kompleks, `Blade::directive()` kustom (perlu padanan Dart: `BladeDirective` registry Daravel + transpilasi closure kompilernya bila sederhana, selain itu TODO).

### 13.4 Kinerja & DX

Output menghindari string concat berulang: `StringBuffer` + penulisan langsung ke `IOSink` untuk respons besar; cache fragment via `@cache` (T2). Hot reload: perubahan `.blade.php` → `view:compile` file itu saja → reload. Error template menunjuk baris Blade (source map) bukan baris Dart.

---

## 14. Konversi Test

### 14.1 Pemetaan

| Laravel (PHPUnit / Pest) | Daravel (`package:test` + `daravel_test`) |
| :-- | :-- |
| `class UserApiTest extends TestCase { use RefreshDatabase; }` | `void main() { setUpDatabase(); group('UserApiTest', () { ... }); }` |
| `public function test_can_list_users(): void` / `it('can list users', fn () => ...)` | `test('can list users', () async { ... });` |
| `$this->getJson('/api/users')->assertOk()->assertJsonCount(3, 'data')` | `(await client.get('/api/users')).assertOk().assertJsonCount(3, 'data')` |
| `$this->actingAs($user, 'sanctum')->postJson(...)` | `client.actingAs(user, guard: 'token').post(..., json: {...})` |
| `User::factory()->count(3)->create()` | `await User.factory().count(3).create()` |
| `$this->assertDatabaseHas('users', [...])` | `await assertDatabaseHas('users', {...})` |
| `Event::fake(); ... Event::assertDispatched(OrderPaid::class)` | `final events = Event.fake(); ... events.assertDispatched<OrderPaid>()` |
| `Queue::fake()`, `Mail::fake()`, `Storage::fake('avatars')`, `Http::fake([...])` | padanan 1:1 (`Http.fake` T2) |
| `$this->travel(5)->days()` / `Carbon::setTestNow()` | `Clock.travel(Duration(days: 5))` / `Clock.freeze(dt)` |
| `$this->withoutExceptionHandling()` | `client.withoutExceptionHandling()` |
| `$this->assertSoftDeleted($user)` | `await assertSoftDeleted(user)` |
| Pest `beforeEach`, `dataset`, `expect($x)->toBe(1)` | `setUp`, parameterized loop, `expect(x, 1)` |
| `#[DataProvider]` | loop `for (final case in cases) test(...)` |

### 14.2 Strategi

- Test feature adalah **prioritas pertama** konversi karena menjadi spesifikasi; test unit yang menguji kelas PHP-internal dikonversi best-effort.
- Assertion yang tidak dipetakan → `fail('DARAGIC-TODO: ...')` agar test **gagal terlihat**, bukan lulus kosong.
- `RefreshDatabase` → transaksi rollback per test (V2 7.11) sehingga kecepatan setara/lebih baik; `DatabaseMigrations` → `migrateFresh()` per test.
- Hasil verify menampilkan tabel: total test, lulus, gagal (karena TODO vs karena perbedaan perilaku) — dua kategori dipisah agar sinyal jelas.

---

## 15. Verifikasi Migrasi

### 15.1 `schema:diff`

Jalankan migrasi Daravel hasil generate pada DB kosong (SQLite/Postgres/MySQL sesuai target), introspeksi hasilnya, bandingkan dengan `schema` aktual di DAM (atau hasil migrasi Laravel pada DB kosong dengan engine yang sama): tabel, kolom (tipe dinormalisasi per dialek, nullable, default, auto-increment, panjang/presisi), indeks (kolom, unik, nama), FK (kolom, referensi, aksi). Perbedaan diklasifikasi `breaking` (tipe/nullable/FK) vs `cosmetic` (nama indeks, komentar). `breaking` menggagalkan `verify`.

### 15.2 Differential Replay (shadow traffic)

- **Perekam** (middleware `daravel/daragic` `RecordRequests`, hanya aktif dengan `DARAGIC_RECORD=1`; **menolak start** bila `APP_ENV=production` atau tanpa konfigurasi anonimisasi, ADR-D02): untuk setiap request menyimpan `method, uri, headers (disaring: tanpa cookie/authorization mentah — token diganti alias `@@user:42`), body, user id, waktu`, respons `status, headers, body`, dan **snapshot DB** ringan: daftar tabel yang disentuh + checksum baris sebelum/sesudah (dari query log), serta seed referensi (`--seed=snapshot.sql` per sesi). Anonimisasi (konfigurasi `daragic-anonymize.yaml`: field PII → hash ber-salt) diterapkan **saat tulis**, sebelum rekaman menyentuh disk; tidak ada mode tanpa anonimisasi (ADR-D02).
- **Pemutar** (`dartisan daragic:replay recordings/ --seed=snapshot.sql`): memuat seed ke DB uji, memetakan alias user ke user yang sama (`actingAs`), mengirim request ke aplikasi Daravel via `TestClient` (tanpa socket) dalam urutan asli, lalu **diff terstruktur**: status, header yang dipilih, body JSON (abaikan field volatil terkonfigurasi: `created_at/updated_at/id/token/*_url` dengan pola), HTML (normalisasi whitespace), dan diff checksum tabel (efek samping DB sama).
- Laporan: per rute — jumlah replay, cocok, beda; perbedaan dikelompokkan (format tanggal, urutan JSON, presisi float, pesan error) dengan saran perbaikan (mis. "cast `price` ke decimal:2").
- Replay juga dipakai sebagai **regresi** setelah tiap perubahan manual.

### 15.3 `MIGRATION_REPORT.md` & Skor Kesiapan

Skor kesiapan (dihitung oleh `analyze`, diperbarui oleh `verify`):

```text
score = 100 × Σ_i (w_i × supported_i) / Σ_i w_i
  i   = unit konversi (rute, model, relasi, aturan, migrasi, resource, policy, job, listener, schedule, command, view, test, pernyataan badan metode)
  w_i = bobot usaha manual bila tidak didukung (rute 1, model 3, relasi 2, migrasi raw 4, pernyataan 0.2, view 2, @php 3, package C 20, Livewire 50)
  supported_i ∈ {0, 0.5 (didukung dengan peringatan semantik), 1}
blockers = daftar terpisah (tidak masuk skor): Livewire/Filament, eval, ekstensi C, package Tier C kritis
estimasi jam = Σ (TODO_jenis × jam_per_jenis) dengan tabel kalibrasi dari korpus (diperbarui tiap rilis)
```

Isi laporan: ringkasan skor, **pita keputusan** (ADR-D04: ≥ 75 disarankan, 50–74 layak dengan persiapan, < 50 belum disarankan; blocker terpisah) & estimasi; cakupan per lapisan (tabel); daftar TODO terurut (file:baris, jenis, saran, tautan docs); package per tier; peringatan semantik (`semantic-risk`) yang perlu review manusia (perbandingan longgar, aritmetika null, regex diterjemahkan); hasil `schema:diff`; hasil test; hasil replay; checklist koeksistensi (Bagian 17) yang terisi otomatis sebagian (rute yang aman dipindah dulu: tanpa TODO, replay cocok, tanpa sesi).

### 15.4 Gerbang Kualitas `verify`

`verify` gagal bila: `dart analyze` error; test terkonversi gagal karena perbedaan perilaku (bukan TODO) di atas ambang `--max-behavior-failures=0`; `schema:diff` breaking; replay beda di atas `--max-replay-diff=0` pada rute yang ditandai `ready`. Semua ambang dapat diatur untuk migrasi bertahap.

---

## 16. Package: Standar DPS & Konversi Package Laravel

### 16.1 Daravel Package Standard (DPS)

Manifest `daravel.yaml` di root package Dart (dibaca `dartisan package:discover`, bukan autodiscovery runtime):

```yaml
dps: 1
name: daravel_permission
provider: lib/src/permission_service_provider.dart#PermissionServiceProvider
config:
  - { key: permission, class: lib/src/config/permission_config.dart#PermissionConfig, publish: config/permission.dart }
migrations: [lib/src/migrations/m_2026_01_01_000000_create_permission_tables.dart#CreatePermissionTables]
routes: []                       # fungsi `void Function(Router)` opsional
commands: [lib/src/commands/cache_reset_command.dart#CacheResetCommand]
middlewareAliases: { role: lib/src/middleware/role_middleware.dart#RoleMiddleware, permission: ... }
policies: []
listeners: []
views: resources/views           # Blade (dikompilasi di aplikasi pengguna saat vendor:publish/compile)
lang: lang
publishes: { config: [...], migrations: [...], views: [...], assets: [...] }
compat:
  laravel: { package: spatie/laravel-permission, version: "^6.0", parity: parity/permission.yaml }
  dam: { exportable: true }       # package menyediakan DAM fragment untuk daragic
```

`dartisan package:discover` memindai `pubspec.lock` → paket yang memiliki `daravel.yaml` → menulis/menyegarkan entri di `bootstrap/packages.dart` (registry eksplisit, ADR-002) — pengguna tetap melihat daftar provider yang aktif. `vendor:publish --package=daravel_permission --tag=config` menyalin aset. Package dapat menyertakan `parity/<name>.yaml` (pemetaan API package Laravel asal ke API Dart-nya) sehingga **kode aplikasi pengguna yang memakai package itu** ikut terkonversi oleh transpiler (mis. `$user->assignRole('admin')` → `await user.assignRole('admin')`).

### 16.2 Pipeline `daragic package:convert vendor/name`

1. Siapkan aplikasi Laravel scratch (`composer create-project` cache lokal), `composer require vendor/name`, boot sandbox.
2. Ekstrak seperti aplikasi, tetapi **dibatasi pada namespace package**: provider (bindings `singleton/bind`, `publishes`, `loadMigrationsFrom`, `loadRoutesFrom`, `loadViewsFrom`, `loadTranslationsFrom`, `commands`, `aliasMiddleware`, `Gate::policy`, `Event::listen`, `Blade::directive/component`), config default, migrasi (recording Blueprint), model/trait (mis. `HasRoles` → mixin), facade (`Permission::` → kelas statik), service kelas, exceptions, middleware, command, Blade, lang, test package.
3. Klasifikasi **per kelas** ke tier (A/B/C) berdasarkan konstruksi Dialect & dependensi (`equivalence.yaml`).
4. Emit package Dart dengan `daravel.yaml`, `parity/<name>.yaml` awal (dibangkitkan dari metode publik + hasil transpilasi), README migrasi, `LICENSE` asli + `NOTICE`.
5. Jalankan test package yang terkonversi; laporan cakupan per kelas.

### 16.3 Tier Hasil

| Tier | Definisi | Hasil |
| :-- | :-- | :-- |
| **A** | Hanya konvensi Laravel (model, migrasi, rute, config, middleware, command, Blade sederhana) + stdlib PHP yang dipetakan | Konversi otomatis penuh; siap pakai setelah review |
| **B** | Bergantung pustaka PHP yang memiliki padanan Dart di `equivalence.yaml` | Konversi + adapter yang dibangkitkan (kelas pembungkus dengan tanda tangan asal) + TODO pada selisih API |
| **C** | Ekstensi C/FFI, Livewire/Filament/Nova UI, `eval`, refleksi berat, protokol khusus tanpa pustaka Dart | Kerangka (`daravel.yaml`, provider, config, migrasi) + laporan; port manual atau "tidak relevan" |

### 16.4 `equivalence.yaml`

```yaml
equivalenceVersion: 1
libraries:
  - { php: guzzlehttp/guzzle, dart: "package:daravel/http_client.dart", adapter: GuzzleLikeClient, tier: B, notes: "async; middleware Guzzle → interceptors" }
  - { php: nesbot/carbon, dart: "package:daravel/support.dart#DateTimeX", tier: B, notes: "immutable; lokal terbatas" }
  - { php: predis/predis, dart: "package:daravel_redis", tier: B }
  - { php: league/flysystem, dart: "package:daravel/storage.dart", tier: A }
  - { php: laravel/sanctum, dart: "builtin:auth.token", tier: A }
  - { php: laravel/horizon, dart: "n/a:queue:monitor", tier: C, notes: "UI tidak diport; gunakan metrics + Pulse-lite" }
  - { php: spatie/laravel-permission, dart: "package:daravel_permission", tier: A, official: true }
  - { php: intervention/image, dart: "package:image", tier: B, verify: true }
  - { php: maatwebsite/excel, dart: "package:excel", tier: B, verify: true }
  - { php: barryvdh/laravel-dompdf, dart: "package:pdf", tier: B, verify: true }
  - { php: livewire/livewire, dart: null, tier: C, blocker: true }
```

`verify: true` menandai pemetaan yang **belum diverifikasi** oleh korpus — `analyze` menampilkannya sebagai "padanan kandidat". Komunitas menambah entri lewat PR dengan contoh.

### 16.5 Port Resmi

Sepuluh package Laravel terpopuler (berdasarkan unduhan Packagist, dievaluasi ulang tiap tahun) mendapat port resmi di organisasi `daravel` sebagai **validasi DPS sekaligus target `equivalence.yaml`**: permission, media library, activity log, backup, query builder, sluggable, excel, dompdf, scout, socialite. Setiap port memiliki `parity/<name>.yaml` dan test yang dikonversi dari upstream.

### 16.6 Lisensi

Header lisensi asli dipertahankan pada setiap file hasil konversi, `NOTICE` dibuat otomatis (nama, versi, lisensi, URL), lisensi non-permisif (GPL/AGPL/proprietary) **memblokir** konversi kecuali `--accept-license` dengan catatan di laporan. Hasil konversi package **bukan** milik Daravel. Tool `daragic` dan semua port resmi berlisensi MIT tanpa fitur terkunci (ADR-D05).

---

## 17. Runbook Koeksistensi (migrasi per-endpoint)

1. **Prasyarat**: Daravel membaca DB yang sama (koneksi, `DB_PREFIX` identik), `APP_KEY` sama (Crypt kompat, Bagian V2 4.4), `CACHE_PREFIX` sama, Redis DB index sama; `Hash` Daravel diset `bcrypt` selama koeksistensi agar Laravel tetap bisa memverifikasi hash yang dibuat Daravel.
2. **Migrasi skema**: hanya **satu** sisi yang menjalankan migrasi pada satu waktu (lock tabel `migrations` + kebijakan tim); migrasi baru ditulis di satu sisi lalu dikonversi (`daragic:export --only=migrations`).
3. **Routing tepi**: nginx/Caddy `location ^~ /api/v2/ { proxy_pass http://127.0.0.1:8000; }` untuk Daravel; sisanya PHP-FPM. Alternatif per-rute halus: daftar prefix dari `MIGRATION_REPORT.md` (rute `ready`), diperbarui per sprint. `TrustProxies` Daravel diset ke proxy tepi.
4. **Autentikasi**: token Sanctum valid di kedua sisi (tabel sama, format sama); JWT memakai secret sama; sesi cookie (T2) memakai driver `database/redis` + enkripsi kompat — sebelum T2, endpoint bersesi tetap di Laravel.
5. **Queue**: pisahkan nama antrean (`php-*` vs `dart-*`) karena payload tidak lintas-runtime; job yang dipindah ke Daravel didispatch dari Daravel saja; scheduler `onOneServer` hanya aktif di satu runtime per task.
6. **Cache**: kunci yang dibaca kedua sisi memakai nilai JSON-serializable (bukan objek PHP ter-serialize); `daragic:analyze` menandai `Cache::put` dengan objek.
7. **Observabilitas**: `X-Request-Id` diteruskan oleh proxy ke kedua runtime; log JSON kedua sisi ke agregator yang sama; dashboard membandingkan latensi/error per rute antar runtime.
8. **Cut-over per rute**: aktifkan di Daravel → shadow replay cocok → alihkan 10% trafik (nginx `split_clients`) → 100% → hapus rute dari Laravel (atau biarkan sebagai fallback 1 sprint).
9. **Rollback**: ubah `location` kembali; tidak ada migrasi data yang perlu dibalik karena DB bersama.
10. **Penyelesaian**: ketika semua rute `ready` dan tervalidasi, PHP-FPM dimatikan; `daragic:export --to-laravel` tetap tersedia sebagai jaminan keluar.

---

## 18. Referensi CLI

### 18.1 Sisi PHP (`php artisan daragic:*` dan `vendor/bin/daragic`, ADR-D06 — kolom "boot?" menandai perintah yang mem-boot aplikasi)

| Perintah | Fungsi | Boot? |
| :-- | :-- | :-- |
| `daragic:analyze [--static] [--phpstan] [--json] [--html=report.html] [--min-score=] [--no-blockers]` | Skor kesiapan + pita (ADR-D04), TODO potensial, blocker, saran refactor/anotasi | runtime: ya; `--static`: tidak |
| `daragic:export [--out=../dam] [--db=dsn] [--only=routes,models,...] [--include-tests] [--include-views] [--parity=12.1]` | Ekstraksi ke DAM | ya |
| `daragic:record [--path=storage/daragic/recordings] [--sample=0.1] --anonymize=<config> [--dry-run]` | Mengaktifkan perekam; `--anonymize` **wajib**; menolak `APP_ENV=production` (ADR-D02) | ya |
| `daragic:import <dam> [--into=.] [--merge] [--pest]` | Daravel → Laravel (emitter PHP; badan metode per ADR-D01) | ya |
| `daragic:package:convert <vendor/name> [--version=] [--out=]` | Konversi package | ya (scratch app) |
| `daragic:parity:check` | Memverifikasi kode aplikasi hanya memakai simbol yang ada di paritas (pra-migrasi) | tidak |
| `daragic:doctor` | Versi Laravel/PHP/ekstensi, PHPStan tersedia, sandbox dapat boot | tidak |
| `daragic:dam:validate <dam>`, `daragic:dam:diff <a> <b>` | Validasi DAM terhadap JSON Schema; diff struktural dua ekspor | tidak |

### 18.2 Sisi Dart (`dartisan daragic:*`)

| Perintah | Fungsi |
| :-- | :-- |
| `daragic:import <dam> [--into=.] [--merge] [--style=faithful\|idiomatic] [--shapes=records\|classes\|maps] [--no-source-map] [--prune]` | DAM → proyek Daravel |
| `daragic:verify [--max-behavior-failures=0] [--max-replay-diff=0] [--db=sqlite\|postgres\|mysql]` | analyze + test + schema:diff + replay |
| `daragic:replay <recordings> --seed=<sql> [--routes=ready] [--ignore=fields.yaml]` | Differential replay |
| `daragic:schema:diff [--against=dam\|laravel]` | Diff skema |
| `daragic:report [--format=md\|json\|html]` | Regenerasi `MIGRATION_REPORT.md` |
| `daragic:modernize [--dry-run] [--path=lib/app]` | Helper `php_compat` → idiom Dart |
| `daragic:export [--to-laravel] [--out=dam/]` | Daravel → DAM |
| `daragic:todo [--list] [--stats]` | Daftar/statistik `DARAGIC-TODO` |
| `daragic:docs:parity` | Bangkitkan dokumentasi side-by-side dari paritas |
| `package:discover`, `vendor:publish --package=` | DPS |

### 18.3 UX

Progress per tahap dengan `mason_logger`; `--json` untuk CI; kode keluar: 0 sukses, 1 kegagalan tool, 3 gerbang `verify` gagal, 4 konflik merge. Pesan TODO selalu menyertakan **tindakan** ("tambahkan `#[Daragic\Type]` di `app/Services/Report.php:42`"). Laporan HTML dapat dibagikan ke pemangku kepentingan non-teknis (skor, estimasi, risiko).

---

## 19. Kualitas Tool

### 19.1 Korpus (`daravel/corpus`)

| Korpus | Isi | Tujuan |
| :-- | :-- | :-- |
| **C0 Snippets** | ±2.000 potongan PHP ↔ Dart (golden) dikelompokkan per fitur Dialect & simbol paritas | Unit test transpiler dua arah |
| **C1 API Starter** | Aplikasi API Laravel (Breeze-style: auth Sanctum, CRUD 5 model, FormRequest, Resource, Policy, 2 job, 1 schedule, 40 test) | Target cakupan ≥ 90% pernyataan, 100% struktural |
| **C2 Admin + Packages** | CRUD + `spatie/laravel-permission` + `maatwebsite/excel` + queue Redis + event/listener + Blade sederhana | Validasi Tier A/B dan Blade gelombang 1 |
| **C3 Web + Inertia/Livewire** | Aplikasi web dengan Blade layout/komponen, Inertia, satu modul Livewire | Mengukur batas (Livewire → C) dan Blade gelombang 2 |
| **C4 Internal pilot** (privat) | Aplikasi nyata milik organisasi pemilik proyek | Kalibrasi estimasi jam & prioritas fitur |

Angka cakupan korpus dipublikasikan per rilis `daragic` (tabel di README) — ini adalah **satu-satunya** sumber klaim pemasaran.

### 19.2 Jenis Test Tool

- **Golden** (C0): PHP → Dart harus sama dengan golden (setelah format) dan **terkompilasi** (`dart analyze` seluruh keluaran golden di CI); Dart → PHP harus lolos `php -l` + PHPStan level 6.
- **Round-trip**: C1/C2 → DAM → Daravel → DAM → Laravel; DAM pertama dan terakhir dibandingkan secara struktural (rute, model, relasi, aturan, migrasi) → harus identik.
- **Diferensial semantik** (`php_compat`): tiap helper dieksekusi di PHP (CLI `php` di CI) dan Dart atas ribuan input acak (seed tetap) → hasil identik; mencakup `truthy`, `looseEquals`, `phpEmpty`, `phpCompare`, `phpDiv`, `phpStrlen/substr`, `phpRound`, `phpJsonEncode`, `phpStr(double)`, `bladeEscape`, penerjemah regex (input adversarial + sampel dari korpus).
- **End-to-end**: C1 dikonversi, test terkonversi dijalankan, replay rekaman C1 dibandingkan → 0 diff di CI (regresi tool).
- **Fuzz**: parser Blade, parser DSL rule, tokenizer SQL raw, pemetaan `env()` diberi input acak; tidak boleh crash (selalu laporan terstruktur).
- **Kompatibilitas versi**: matriks Laravel 10/11/12 × PHP 8.2/8.3/8.4 × Daravel target.

### 19.3 CI

Workflow menjalankan PHP (`composer`, `php`, PHPStan) **dan** Dart dalam satu job (container multi-tool) + MySQL/Postgres service; artefak laporan cakupan per korpus diunggah; regresi cakupan > 1 poin menggagalkan CI.

---

## 20. Keamanan & Privasi Tool

- Extractor **tidak pernah** mengekspor nilai `.env`, kredensial, atau isi tabel; DAM hanya memuat struktur. `--db` selalu read-only (transaksi rollback + `READ ONLY`).
- Rekaman trafik: anonimisasi wajib (konfigurasi `daragic-anonymize.yaml`: field PII → hash/salt, header sensitif dibuang, body > N KB dipotong), disimpan terenkripsi (`Crypt` Laravel) bila `--encrypt`; perekam **menolak** berjalan di `APP_ENV=production` dan tanpa konfigurasi anonimisasi (ADR-D02); retensi default 30 hari dengan penghapusan otomatis; persetujuan hukum (UU PDP) dicatat di checklist laporan.
- Sandbox boot memblokir HTTP keluar (`preventStrayRequests`), mail, broadcast, dan menolak `APP_ENV=production`.
- Kode hasil generate tidak menyisipkan kredensial; `.env.example` Daravel dibangkitkan dari kunci, bukan nilai.
- Supply chain: `daragic` PHP tanpa dependensi runtime selain `nikic/php-parser` dan (opsional) PHPStan; Dart tanpa dependensi selain `analyzer`, `yaml`, `daravel`, `dartisan_cli`; semua dipin dan diaudit (`composer audit`, `dart pub outdated`).
- Keluaran transpiler tidak pernah memakai `eval`/`Function`/refleksi; konstruksi PHP yang dinamis menjadi TODO — ini juga mencegah "menerjemahkan kerentanan" (mis. SQL interpolasi PHP → di Dart menjadi `DB.select` **dengan binding** atau TODO `semantic-risk`, tidak pernah interpolasi).

---

## 21. Performa Tool

- Ekstraksi: satu boot aplikasi + refleksi → detik; AST seluruh `app/` dengan php-parser → puluhan detik untuk 100k LOC; PHPStan dump adalah langkah terlama (menit) dan dapat di-cache (`--phpstan-cache`).
- Transpilasi di Dart: paralel per file dengan `Isolate.run`; 100k LOC PHP → target < 2 menit pada mesin 8 core (diukur korpus, bukan janji).
- Merge inkremental hanya menyentuh entitas dengan hash berubah.
- Replay: `TestClient` tanpa socket → ribuan request/detik; seed DB dimuat sekali per sesi rekaman.

---

## 22. Peta Jalan `daragic`

| Tahap | Lingkup | Exit criteria |
| :-- | :-- | :-- |
| **D0 — Fondasi** (paralel Daravel S5–S7) | DAM v1 + JSON Schema; sandbox booter; extractor rute/middleware/model/relasi/migrasi (recording Blueprint)/config/env/validation/policy/job/event/schedule/command; emitter Dart struktural via `Scaffolder`; `analyze` v1 (skor struktural); `parity.yaml` awal (±300 simbol); `daragic.lock` | C1 struktural 100% terkonversi & terkompilasi; round-trip struktural identik; `analyze` menghasilkan laporan |
| **D1 — Badan metode & test** (paralel S8–S11) | Dialect IR; lowering PHP → IR (php-parser) & IR → Dart; PHPStan dump; async propagation; `php_compat` + test diferensial; tabel stdlib ±350; konversi test; `schema:diff`; `verify`; laporan v2 (estimasi jam) | C1 ≥ 90% pernyataan tanpa TODO, test terkonversi hijau; `dart analyze` 0 error pada semua keluaran korpus |
| **D2 — Blade, package, replay, arah balik struktural** (Tier 2 awal Daravel) | Kompiler Blade gelombang 1 (+ komponen dasar); DPS + `package:discover` + `package:convert` Tier A/B; `equivalence.yaml`; recorder + replayer + differ; `dartisan daragic:export` + emitter PHP struktural; merge 3-arah; `modernize` v1; port resmi 3 package | C2 terkonversi (Blade + permission + excel) dengan laporan; replay C1 0 diff; round-trip C1 identik struktural |
| **D3 — Arah balik penuh & gelombang 2** (bersyarat, ADR-D01) | Dart → PHP badan metode (analyzer resolved) **hanya bila permintaan pengguna pasca-D2 membenarkan**; Blade gelombang 2 (slot/komponen class-based/stack); Dialect gelombang 2 (generators, static locals, trait lanjutan); package arah balik; port resmi 10 package; `docs:parity`; laporan HTML | C3 terukur (Livewire dilaporkan C, sisanya terkonversi); 10 port resmi; dokumentasi side-by-side dibangkitkan |

KPI per rilis: cakupan C1/C2/C3, jumlah simbol paritas `identical`, waktu konversi C1, jumlah TODO per 1k LOC, akurasi estimasi jam (dibandingkan pilot C4).

---

## 23. Risiko & Mitigasi

| Risiko | Mitigasi |
| :-- | :-- |
| Klaim berlebih merusak kepercayaan | Angka hanya dari korpus publik; laporan selalu menyebut TODO & peringatan; dokumentasi memakai "terkonversi sebagian" bukan "otomatis" |
| Kode terkompilasi tetapi salah secara halus (semantik PHP) | Mode `faithful` default; helper diuji diferensial; `semantic-risk` wajib review; replay |
| Paritas tertinggal rilis Laravel tahunan | Paritas berversi; CI Daravel memverifikasi simbol; kalender rilis: paritas baru ≤ 60 hari setelah Laravel mayor |
| Introspeksi runtime gagal karena provider pihak ketiga | `--skip-provider`, fallback AST, laporan dampak |
| Relasi/aturan yang bergantung kondisi runtime | AST + anotasi + TODO terarah |
| Kompleksitas merge menimbulkan kehilangan suntingan | Suntingan manusia selalu menang di luar region; konflik eksplisit; `.daragic/base` disimpan; test E2E merge |
| Lisensi package pihak ketiga | Deteksi lisensi, blokir non-permisif, header & NOTICE |
| Privasi rekaman trafik | Anonimisasi wajib, enkripsi, dokumentasi kepatuhan |
| Dua extractor (PHP & Dart) menyimpang | DAM + JSON Schema sebagai kontrak; round-trip test |
| Ketergantungan `nikic/php-parser`/PHPStan berubah | Pin versi; abstraksi tipis; test korpus |

---

## 24. Keputusan yang Ditetapkan & Pertanyaan Terbuka

### 24.1 Keputusan Pemilik Proyek (ADR daragic, 2026-10-23)

#### ADR-D01 — Kedalaman arah balik Daravel → Laravel

- **Konteks.** Arah balik penuh (badan metode Dart → PHP, tahap D3) mahal untuk dibangun dan dirawat, sementara nilai pasarnya belum terbukti. Arah balik struktural + test (D2) sudah memberi jaminan keluar yang berarti.
- **Keputusan.** D3 **diputuskan setelah D2 berdasarkan permintaan pengguna**. IR (DAM + Dialect IR) dan `parity.yaml` **tetap simetris sejak D0**.
- **Konsekuensi.**
  1. Simetri ditegakkan secara mesin sejak D0: setiap field DAM memiliki extractor dan emitter di kedua sisi untuk artefak struktural; Dialect IR tidak boleh memuat node khusus-PHP tanpa padanan Dart (dan sebaliknya) — `Opaque` adalah satu-satunya pengecualian; round-trip test struktural (Bagian 19.2) wajib hijau sejak D0.
  2. Sampai D3 diputuskan, `dartisan daragic:export --to-laravel` memancarkan artefak struktural dan test secara penuh, dan badan metode sebagai `LARAGIC-TODO` yang memuat sumber Dart asli sebagai komentar.
  3. Metrik permintaan dikumpulkan sejak D1: isu dan permintaan pengguna pilot untuk `to-laravel` badan metode dihitung; ambang keputusan (misalnya ≥ 3 dari 5 pengguna pilot meminta) ditetapkan di akhir D2 dan hasilnya dicatat sebagai ADR-D07 (nomor dipesan).
  4. Lowering Dart → Dialect IR untuk badan metode **tetap** dibangun di D2 sebatas yang dibutuhkan konversi test, sehingga D3 (bila disetujui) tinggal menambah codegen PHP, bukan redesain.

#### ADR-D02 — Perekaman trafik hanya di staging dengan anonimisasi wajib

- **Konteks.** Differential replay membutuhkan rekaman request/response nyata. Perekaman di produksi memberi cakupan terbaik tetapi membawa risiko privasi (UU PDP) dan beban kepatuhan.
- **Keputusan.** Perekaman **hanya di staging**; **anonimisasi wajib**.
- **Konsekuensi.**
  1. Perekam **menolak start** bila `APP_ENV=production` — *hard block* tanpa flag override.
  2. Perekam **menolak start** tanpa `--anonymize=<config>`; anonimisasi diterapkan **saat tulis**, sebelum rekaman menyentuh disk; tidak ada mode tanpa anonimisasi.
  3. Daftar field PII bawaan (`email, phone, name, address, nik, nip, dob, token, password, authorization, cookie, otp`) ditambah konfigurasi proyek; nilai diganti hash ber-salt per sesi agar relasi antar request tetap terjaga tanpa membuka identitas.
  4. `daragic:record --dry-run` memverifikasi konfigurasi terhadap sampel request dan menampilkan field yang akan disamarkan.
  5. Setiap set rekaman menyertakan manifest anonimisasi (hash konfigurasi + versi perekam); `dartisan daragic:replay` **menolak** rekaman tanpa manifest.
  6. Retensi default 30 hari dengan penghapusan otomatis; checklist kepatuhan (persetujuan hukum, retensi, akses) menjadi bagian `MIGRATION_REPORT.md`.
  7. Cakupan replay yang hilang karena tidak merekam produksi dikompensasi dengan **seed staging yang representatif** (`daragic:seed:sample` menyalin subset data produksi yang sudah dianonimkan ke staging, T2) dan test terkonversi.

#### ADR-D03 — Bentuk (shape) array PHP: `records` lokal, `classes` lintas batas publik

- **Konteks.** Array shape PHP (`array{id:int, name:string}`) harus menjadi sesuatu yang bertipe di Dart. Record ringkas tetapi tidak dapat diberi doc comment atau metode dan canggung bila dipakai di banyak tempat; kelas data lebih berat tetapi dapat didokumentasi dan dipakai ulang.
- **Keputusan.** Default **otomatis**: shape yang hanya hidup di dalam satu badan fungsi → **record** `({int id, String name})`; shape yang muncul pada **batas publik** (parameter, return, properti, DAM `jobs.props`, resource, event) atau dipakai di ≥ 2 fungsi → **kelas data** yang di-generate; `maps` hanya sebagai fallback mode `faithful` bila tipe tidak diketahui. Flag `--shapes=records|classes|maps` menimpa secara global, atribut `#[Daragic\Shape('class')]` per lokasi.
- **Konsekuensi.**
  1. Kelas data ditulis ke `lib/app/support/shapes/<name>.dart` dengan `const` konstruktor, `fromMap/toMap`, `copyWith`, `==`/`hashCode`, dan doc comment dari docblock asal; nama diambil dari alias PHPStan `@phpstan-type Nama` bila ada, selain itu dari konteks (`StoreProductPayload`, `ReportRow`).
  2. Shape yang **identik secara struktural** di-dedup menjadi satu kelas (peta hash struktur → nama) dan dilaporkan agar developer dapat merapikan nama.
  3. Arah balik: kelas data → `array{...}` + `@phpstan-type` di PHP sehingga round-trip tidak kehilangan tipe.
  4. `modernize` dapat mengangkat record menjadi kelas bila record mulai melintasi batas setelah suntingan manusia (saran, bukan otomatis).

#### ADR-D04 — Pita skor kesiapan migrasi

- **Konteks.** Skor 0–100 (Bagian 15.3) membutuhkan interpretasi yang konsisten untuk keputusan *go/no-go* dan untuk gerbang CI.
- **Keputusan.** Tiga pita, dengan *blocker* dihitung terpisah dan selalu menggagalkan pita tertinggi: **≥ 75 tanpa blocker → "disarankan migrasi"**; **50–74 atau ada blocker non-kritis → "layak dengan persiapan"** (laporan wajib menyertakan daftar refactor PHP yang diperkirakan menaikkan skor ke ≥ 75 beserta estimasi jam); **< 50 → "belum disarankan"**. Ambang **dikalibrasi** dengan pilot C4 di akhir D1 (ADR-D04 direvisi bila kalibrasi mengubah angka) dan dapat ditimpa per proyek di `daragic.yaml` (`readiness.thresholds`).
- **Konsekuensi.**
  1. `daragic:analyze` mencetak pita + alasan (tiga kontributor terbesar penurunan skor) + "jalur tercepat ke pita berikutnya".
  2. Gerbang CI opsional `--min-score=<n>` dan `--no-blockers` untuk memantau kesiapan proyek Laravel yang masih berkembang (skor tidak boleh turun di bawah baseline).
  3. Laporan HTML menampilkan pita secara visual untuk pemangku kepentingan non-teknis; angka selalu disertai metodologi (Bagian 15.3) agar tidak disalahartikan sebagai jaminan.

#### ADR-D05 — Lisensi tool, port resmi, dan model komunitas

- **Konteks.** Perlu kejelasan apakah sebagian kemampuan (laporan HTML, port package resmi) dijadikan fitur berbayar.
- **Keputusan.** **Seluruh tool `daragic` dan semua port package resmi berlisensi MIT tanpa fitur yang dikunci** (termasuk `analyze`, `export`, `import`, `verify`, `replay`, laporan HTML, `package:convert`). Monetisasi, bila dilakukan, hanya lewat **layanan**: dukungan migrasi, pelatihan, SLA untuk port resmi, dan (kemudian) layanan hosted opsional seperti dashboard kesiapan multi-proyek — tidak pernah dengan menahan kemampuan dari versi open-source.
- **Konsekuensi.**
  1. Tata kelola: organisasi GitHub `daravel`, `CONTRIBUTING.md`, **DCO sign-off** (bukan CLA) untuk menurunkan friksi kontribusi, proses RFC ringan untuk perubahan DAM/`parity.yaml` (PR + 7 hari tinjauan + 2 persetujuan maintainer), label `good-first-parity` untuk entri paritas/ekuivalensi baru.
  2. Kontribusi paritas wajib menyertakan kasus korpus (Bagian 11.2); kontribusi port package wajib menyertakan test yang dikonversi dari upstream.
  3. Angka cakupan korpus dipublikasikan di README setiap rilis (D10) sebagai bentuk akuntabilitas publik.
  4. Layanan berbayar tidak boleh memengaruhi prioritas isu open-source secara tersembunyi; roadmap publik di GitHub Projects.

#### ADR-D06 — Bentuk perintah sisi PHP: Artisan **dan** binary mandiri

- **Konteks.** Perintah Artisan memberi akses ke container dan introspeksi runtime; binary mandiri berguna di CI dan untuk analisis statis tanpa mem-boot aplikasi.
- **Keputusan.** **Keduanya**, dari satu basis kode: `php artisan daragic:*` untuk operasi yang membutuhkan aplikasi ter-boot (`export`, `record`, `package:convert`, `analyze` mode runtime, `import` ke Laravel) dan `vendor/bin/daragic` (composer bin, tanpa PHAR) untuk operasi tanpa boot (`analyze --static`, `parity:check`, `doctor`, `dam:validate`, `dam:diff`) — binary mem-boot aplikasi secara otomatis hanya bila sub-perintah memerlukannya (deteksi `bootstrap/app.php`).
- **Konsekuensi.**
  1. Perintah adalah pembungkus tipis atas layanan `Daragic\Kernel` (`Analyzer`, `Exporter`, `Recorder`, `PackageConverter`, `Importer`) sehingga tidak ada logika yang terduplikasi.
  2. Dokumentasi menyajikan satu tabel perintah dengan kolom "butuh boot?" (Bagian 18.1).
  3. CI yang hanya memantau kesiapan dapat memakai `vendor/bin/daragic analyze --static --min-score=75` tanpa DB atau `.env`.

### 24.2 Masih Terbuka

Tidak ada. Pertanyaan baru dicatat di sini dan diputuskan lewat ADR-D berikutnya (nomor berikutnya yang tersedia: ADR-D07 dipesan untuk keputusan D3 pasca-D2; keputusan baru mulai ADR-D08).

---

## 25. Lampiran

### 25.1 Contoh End-to-End (PHP → Dart, mode `faithful`)

```php
// app/Http/Controllers/Api/ProductController.php
public function store(StoreProductRequest $request): JsonResponse
{
    $data = $request->validated();
    $product = DB::transaction(function () use ($data, $request) {
        $product = Product::create($data);
        if ($request->has('tags')) {
            $product->tags()->sync($request->input('tags'));
        }
        return $product->load('category', 'tags');
    });
    ProductCreated::dispatch($product);
    return (new ProductResource($product))->response()->setStatusCode(201);
}
```

```dart
// lib/app/http/controllers/api/product_controller.dart  (GENERATED BY daragic from app/Http/Controllers/Api/ProductController.php)
Future<Object?> store(Request req) async {
  final data = await FormRequest.run(StoreProductRequest(), req);                      // daragic: ProductController.php:14
  final product = await DB.transaction(() async {                                      // :15
    final product = await Product.create(data.toMap());                                // :16
    if (await req.has('tags')) {                                                       // :17
      await product.belongsToMany<Tag>('tags').sync(await req.input<List<Object?>>('tags') ?? const []); // :18
    }
    return product.load(['category', 'tags']);                                         // :20
  });
  await Events.dispatch(ProductCreated(product));                                      // :22
  return Response.created(ProductResource(product));                                   // :23
}
```

Laporan untuk metode ini: 9 pernyataan, 9 terkonversi, 1 peringatan `semantic-risk` (`input('tags')` tanpa tipe → `List<Object?>`; saran: `#[Daragic\ListOf('int')]` atau aturan `tags.*|integer` di FormRequest yang membuat tipe terbukti).

### 25.2 Contoh DAM Model (dipotong)

```json
{ "name": "Product", "fqcn": "App\\Models\\Product", "table": "products",
  "key": { "name": "id", "type": "autoInt", "incrementing": true },
  "fillable": ["sku", "name", "price", "category_id"],
  "casts": { "price": "decimal:2", "meta": "array", "published_at": "datetime" },
  "softDeletes": true, "timestamps": true,
  "relations": [
    { "name": "category", "type": "belongsTo", "related": "App\\Models\\Category", "foreignKey": "category_id", "ownerKey": "id" },
    { "name": "tags", "type": "belongsToMany", "related": "App\\Models\\Tag", "pivot": { "table": "product_tag", "foreignPivotKey": "product_id", "relatedPivotKey": "tag_id", "withTimestamps": true } } ],
  "scopes": { "published": { "source": { "path": "sources/models/Product.scopePublished.ir.json", "hash": "sha256:…", "lang": "php", "coverage": 1.0 } } },
  "observers": ["App\\Observers\\ProductObserver"], "unsupported": [], "hints": [] }
```

### 25.3 Glosarium

**DAM** — Daravel Application Model, IR berversi. **Dialect IR** — AST bahasa-netral untuk subset Laravel. **Lowering** — konversi AST bahasa → Dialect IR. **Faithful/Idiomatic** — gaya keluaran transpiler. **`php_compat`** — helper semantik PHP di Daravel. **Recording Blueprint** — perekam operasi skema migrasi tanpa eksekusi SQL. **Replay** — pemutaran ulang trafik terekam untuk diff perilaku. **DPS** — Daravel Package Standard (`daravel.yaml`). **Tier A/B/C** — klasifikasi konversi package. **Round-trip** — Laravel → Daravel → Laravel untuk menguji simetri IR. **`DARAGIC-TODO`** — penanda konstruksi yang butuh tangan manusia.

---

*Akhir BLUEPRINT DARAGIC 1.2 (2026-10-23). Perubahan dicatat sebagai ADR di `docs/adr/daragic/`.*
