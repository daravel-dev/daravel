<!-- source: README.md sha256:75a35e280ac5 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_mysql

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_mysql/README.md) · Bahasa Indonesia

Driver MySQL dan MariaDB untuk [Daravel](https://pub.dev/packages/daravel),
di atas client Dart murni [`mysql_dart`](https://pub.dev/packages/mysql_dart).
Dengan driver ini, aplikasi Daravel bisa berbagi database MySQL dengan
aplikasi Laravel: tabel-tabel framework, token Sanctum, dan hasil query sama
dengan Laravel 12.

```bash
dart pub add daravel_mysql
```

```dart
// bootstrap/app.dart
import 'package:daravel_mysql/daravel_mysql.dart';

Application createApp() => Application.configure(basePath: '.')
    .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
    .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
    // ...
    .create();
```

```dotenv
DB_CONNECTION=mysql        # atau mariadb
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=shop
DB_USERNAME=shop
DB_PASSWORD=secret
DB_SSLMODE=disable         # require / verify-full menyalakan TLS
DB_TIMEZONE=               # zona waktu session opsional, seperti `timezone` di Laravel
```

- Diuji di MySQL 8.4 (`caching_sha2_password`) serta MariaDB 11 dan 12.
- Nilai dengan binding dijalankan sebagai prepared statement di sisi server.
- Hasil query terbaca seperti di Laravel: `TINYINT(1)` sebagai `0`/`1`,
  `DECIMAL` dan `JSON` sebagai string, tanggal sebagai teks `Y-m-d H:i:s`.
- Zona waktu session mengikuti server kecuali `DB_TIMEZONE` di-set, sehingga
  kolom `TIMESTAMP` terbaca sama dari Laravel dan Daravel.
- Deadlock dan lock wait timeout dicoba ulang oleh
  `DB.transaction(attempts: n)`.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/database.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; MySQL adalah merek dagang Oracle; MariaDB adalah
merek dagang MariaDB plc. Daravel adalah proyek independen, tidak
berafiliasi dengan maupun didukung oleh pihak mana pun di antaranya.
