<!-- source: README.md sha256:c3fc21577cca -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_postgres

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_postgres/README.md) · Bahasa Indonesia

Driver PostgreSQL untuk [Daravel](https://pub.dev/packages/daravel).

```bash
dart pub add daravel_postgres       # atau: dart run bin/dartisan.dart db:install pgsql
```

```dart
// bootstrap/app.dart
import 'package:daravel_postgres/daravel_postgres.dart';

Application createApp() => Application.configure(basePath: '.')
    .withPostgres()
    // ...
    .create();
```

```dotenv
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=secret
DB_SSLMODE=disable         # require / verify-full menyalakan TLS
DB_POOL_SIZE=10
```

## Mengapa paket terpisah untuk driver yang sudah dimiliki Daravel

Selama Daravel 1.x, driver PostgreSQL tertanam di `package:daravel`. Paket
ini meng-export ulang driver itu, jadi menambahkannya tidak mengubah apa pun
saat runtime. `package:daravel_mysql` sudah bekerja dengan cara ini untuk
MySQL dan MariaDB.

Di Daravel 2.0, core tidak lagi bergantung pada client database mana pun,
dan driver hanya ada di sini. Proyek yang bergantung pada `daravel_postgres`
dan memanggil `.withPostgres()` tetap berjalan tanpa perubahan. Proyek itu
juga tidak lagi mem-build atau menyertakan client database yang tidak
dipakainya.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/database.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; PostgreSQL adalah merek dagang PostgreSQL Community
Association of Canada. Daravel adalah proyek independen, tidak berafiliasi
dengan maupun didukung oleh pihak mana pun di antaranya.
