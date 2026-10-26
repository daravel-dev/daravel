<!-- source: README.md sha256:782ca034fe5f -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_sqlite

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_sqlite/README.md) · Bahasa Indonesia

Driver SQLite untuk [Daravel](https://pub.dev/packages/daravel).

```bash
dart pub add daravel_sqlite       # atau: dart run bin/dartisan.dart db:install sqlite
```

```dart
// bootstrap/app.dart
import 'package:daravel_sqlite/daravel_sqlite.dart';

Application createApp() => Application.configure(basePath: '.')
    .withSqlite()
    // ...
    .create();
```

```dotenv
DB_CONNECTION=sqlite
DB_DATABASE=database/database.sqlite   # atau :memory: untuk test
```

## Mengapa paket terpisah untuk driver yang sudah dimiliki Daravel

Selama Daravel 1.x, driver SQLite tertanam di `package:daravel`. Paket ini
meng-export ulang driver itu, jadi menambahkannya tidak mengubah apa pun
saat runtime. `package:daravel_mysql` sudah bekerja dengan cara ini untuk
MySQL dan MariaDB.

Di Daravel 2.0, core tidak lagi bergantung pada client database mana pun,
dan driver hanya ada di sini. Proyek yang bergantung pada `daravel_sqlite`
dan memanggil `.withSqlite()` tetap berjalan tanpa perubahan. Proyek itu
juga tidak lagi mem-build atau menyertakan client database yang tidak
dipakainya.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/database.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; SQLite berada di domain publik. Daravel adalah
proyek independen, tidak berafiliasi dengan maupun didukung oleh pihak mana
pun di antaranya.
