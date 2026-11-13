<!-- source: README.md sha256:de3907ecbed3 -->
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
dengan peringatan). Seperti di analyzer, severity (`info`, `warning`,
`error`) atau daftar nama juga menyalakan rule; untuk mematikannya tulis
`false`, bukan `ignore` (analysis server membaca `ignore` di sana sebagai
menyala, sehingga `dartisan lint` menolaknya). Hanya berkas proyek itu
sendiri yang dibaca: `include:`
tidak ditelusuri, dan di pub workspace yang dibaca adalah berkas paket
tempat `dartisan` dijalankan. `dartisan lint --enable=<rule>` dan
`--disable=<rule>` mengubah satu kali jalan, dan baris ringkasannya menyebut
rule opt-in yang dijalankan. Di kode: `lintProject(root, rules:
lintConfig(root).rules)`.

| Rule | Menangkap |
| :-- | :-- |
| `prefer_sql_identifier` | nama kolom yang diberikan ke method query builder (`where`, `orderBy`, `select`, `pluck`, ...) yang bukan string literal, bukan `const`, bukan pilihan di antara literal (`sort == 'name' ? 'name' : 'id'`), dan bukan `SqlIdentifier`. Query yang diawali static model (`Region.where(sort)`, passthrough yang ditulis `make:model`) dinilai di pemanggilnya, bukan di passthrough-nya: model adalah kelas di `lib/app/models` yang `extends Model`, langsung atau lewat kelas di folder itu (plugin editor menanyakan kelas yang ter-resolve) |
| `string_validation_rule` | daftar rule berupa string (`'required\|email\|max:255'`) yang bisa diganti rantai `Rules` dengan arti yang sama (`Rules.required().email().max(255)`), yang dilengkapi editor dan diperiksa compiler; pesannya menyebut rantai itu. Tidak dilaporkan bila tidak ada rantai yang persis sama (`regex`, rule yang tidak dikenal, `min` yang bukan angka) |
| `string_column_name` | nama kolom yang ditulis sebagai string di query model (`User.query().where('email', x)`, `User.where(...)`) bila record `cols` model itu memuat kolom tersebut, di method yang menerima kolom bertipe (`where`, `orWhere`, `orderBy`, `latest`, `pluck`, `select`, `count`, ...): pesannya menyebut tokennya (`User.cols.email`). Rule ini membaca `lib/app/models` proyek (`StringColumnName.forProject(root)`, yang dibangun `LintConfig.rulesIn(root)` begitu rule ini dinyalakan, di `dartisan lint` dan `expectLintClean()`; plugin editor hanya membaca model yang dirujuk tiap berkas, di bawah `lib/app/models` paketnya, dan membaca ulang model yang berubah). Fix-nya menulis token itu (`(removes const)` bila `const` list `select([...])` ikut dihapus; tidak di list bertipe `<String>`); `whereIn`, `whereNull`, dan sejenisnya menerima `String` sehingga tidak dilaporkan |

`SqlIdentifier('users.id')` memeriksa sebuah nama sekali, saat dibuat (nama
polos yang digabung dengan titik, selain itu `ArgumentError`), dan builder
meng-quote-nya sama seperti string yang sama. Daftar kolom yang diizinkan
tetap pemeriksaan yang lebih baik untuk nama yang datang dari request:
`SqlIdentifier` hanya menolak karakter yang aneh, kolom apa pun yang ada
tetap lolos.

`string_validation_rule` juga bisa menuliskan rantainya untuk Anda:
`rule.fixFor(unit, node)` mengembalikan `LintFix` (pesan seperti
`Write as Rules.required().email()` beserta edit teksnya), yang ditawarkan
plugin editor sebagai quick fix, untuk satu temuan atau semua temuan dalam
berkas. Fix hanya ditawarkan bila rantainya compile dan artinya sama:
- satu string literal polos (bukan interpolasi, bukan string yang
  berdampingan);
- tidak berada di list atau map yang bertipe string, baik lewat argumen
  tipenya sendiri (`<String>[...]`, `<String, String>{...}`) maupun lewat
  deklarasi yang diinisialisasi atau dikembalikannya (variabel atau field
  bertipe `Map<String, String>`, method, getter, atau fungsi yang
  dideklarasikan mengembalikan tipe itu, misalnya override `rules()`);
- di konteks `const` hanya bila cukup dengan menghapus `const` pada list
  atau map yang membungkusnya, tidak pernah di variabel `const` atau
  pemanggilan constructor `const`. Pesannya kemudian diakhiri
  `(removes const)`: elemen lain juga kehilangan konteks konstannya,
  sehingga `[Foo(), 'required']` membuat `Foo` baru setiap kali;
- tidak bila import `package:daravel/daravel.dart` di berkas itu
  menyembunyikan `Rules`. Prefix import dipakai, dan import ditambahkan
  bila belum ada.

Tanpa resolusi, rule ini tidak bisa melihat tipe yang datang dari tempat
lain, misalnya map yang diberikan ke parameter bertipe
`Map<String, String>` di fungsi Anda sendiri. Di sana fix bisa
menghasilkan kode yang tidak compile, dan editor langsung menunjukkan
galatnya.

`rule.fixesIn(unit)` mengembalikan semua fix dalam satu berkas, dan
`LintFixMerger` menggabungkannya sehingga edit yang sama dari dua fix hanya
dibuat sekali. `string_column_name` juga menawarkan fix (lihat tabel); rule
lain tidak menawarkan fix (alasannya untuk tiap rule ada di
`LintRule.fixFor`). `fixSource(source, path, rules: ...)` menerapkan semua
fix dalam satu berkas, tanpa menyentuh temuan yang dibungkam
`// daravel-lint-ignore:`, seperti `dartisan lint --fix`.

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
