<!-- source: README.md sha256:bf6a9b02b1d7 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_lints

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_lints/README.md) · Bahasa Indonesia

Rule lint AST untuk aplikasi [Daravel](https://pub.dev/packages/daravel),
dijalankan oleh `dartisan lint` dan di test (bukan plugin analyzer IDE).

| Rule | Menangkap |
| :-- | :-- |
| `no_dart_mirrors` | `dart:mirrors`, yang tidak bisa dipakai biner AOT |
| `no_print_in_app` | `print` di `lib/app` (pakai `Log`, yang meredaksi secret dan menambahkan konteks request) |
| `no_mutable_static_in_app` | static dan global yang bisa diubah dan dipakai bersama oleh setiap request |
| `no_sql_string_interpolation` | SQL yang dibangun dengan interpolasi atau penggabungan string alih-alih binding |
| `invalid_validation_rule` | rule validasi yang tidak dikenal dan argumen yang hilang (`max` tanpa nilai) |
| `unawaited_in_db_transaction` | query di dalam `DB.transaction` yang tidak di-`await` |
| `invalid_timezone` | nama zona waktu yang tidak dikenal scheduler |
| `no_inline_js_interpolation` | nilai yang diinterpolasi ke handler inline `on*=` di HTML yang dibangkitkan; escape HTML tidak mencegah tanda kutip menutup string JavaScript (pakai atribut `data-*` dan `addEventListener`) |
| `registry_entry_missing` | migrasi, job, policy, listener, atau command yang tertinggal dari `bootstrap/` |

### Rule opt-in

Rule berikut hanya berjalan bila proyek mengaktifkannya, di test arsitektur
(`expectLintClean(null, ['prefer_sql_identifier'])` dari `daravel_test`)
atau lewat `lintProject(root, rules: rulesWith(['prefer_sql_identifier']))`.
`dartisan lint` hanya menjalankan rule default.

| Rule | Menangkap |
| :-- | :-- |
| `prefer_sql_identifier` | nama kolom yang diberikan ke method query builder (`where`, `orderBy`, `select`, `pluck`, ...) yang bukan string literal, bukan `const`, bukan pilihan di antara literal (`sort == 'name' ? 'name' : 'id'`), dan bukan `SqlIdentifier` |
| `raw_env_outside_config` | variabel environment yang dibaca di kode aplikasi di luar `lib/config/` (`env('X')`, `make<Env>()`, `EnvKeys.*`, `Platform.environment`): bagian config divalidasi saat boot lalu dibekukan, jadi baca nilainya lewat bagian config. Menyala di proyek baru |

`SqlIdentifier('users.id')` memeriksa sebuah nama sekali, saat dibuat (nama
polos yang digabung dengan titik, selain itu `ArgumentError`), dan builder
meng-quote-nya sama seperti string yang sama. Daftar kolom yang diizinkan
tetap pemeriksaan yang lebih baik untuk nama yang datang dari request:
`SqlIdentifier` hanya menolak karakter yang aneh, kolom apa pun yang ada
tetap lolos.

Abaikan sebuah temuan dengan `// daravel-lint-ignore: <rule>` di baris yang
sama atau di baris atasnya.

```dart
import 'package:daravel_lints/daravel_lints.dart';

final issues = lintSource(source, 'lib/app/http/controllers/search.dart');
```

Lihat [`example/main.dart`](example/main.dart).

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak berafiliasi
dengan maupun didukung oleh keduanya.
