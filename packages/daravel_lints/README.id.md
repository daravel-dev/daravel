<!-- source: README.md sha256:4fe905f79ff3 -->
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
| `registry_entry_missing` | migrasi, job, policy, listener, atau command yang tertinggal dari `bootstrap/` |

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
