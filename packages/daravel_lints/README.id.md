<!-- source: README.md sha256:bd0b68ca67a4 -->
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

Rule berikut hanya berjalan bila proyek mengaktifkannya, di bawah
`diagnostics:` dalam `analysis_options.yaml`, yang dibaca `dartisan lint`
dan `expectLintClean()` dari `daravel_test` (plugin editor membaca bentuk
`plugins:`):

```yaml
daravel_lints:              # atau plugins: daravel_lints_plugin:, dengan plugin
  diagnostics:
    prefer_sql_identifier: true   # rule opt-in menyala
    no_print_in_app: false        # rule default mati
```

Bila proyek memakai plugin, blok `plugins: daravel_lints_plugin:
diagnostics:` yang dibaca (blok `daravel_lints:` di sebelahnya diabaikan,
dengan peringatan). Hanya berkas proyek itu sendiri yang dibaca: `include:`
tidak ditelusuri, dan di pub workspace yang dibaca adalah berkas paket
tempat `dartisan` dijalankan. `dartisan lint --enable=<rule>` dan
`--disable=<rule>` mengubah satu kali jalan, dan baris ringkasannya menyebut
rule opt-in yang dijalankan. Di kode: `lintProject(root, rules:
lintConfig(root).rules)`.

| Rule | Menangkap |
| :-- | :-- |
| `prefer_sql_identifier` | nama kolom yang diberikan ke method query builder (`where`, `orderBy`, `select`, `pluck`, ...) yang bukan string literal, bukan `const`, bukan pilihan di antara literal (`sort == 'name' ? 'name' : 'id'`), dan bukan `SqlIdentifier` |

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
