<!-- source: README.md sha256:569487f81c44 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_permission

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_permission/README.md) · Bahasa Indonesia

Role dan permission di database untuk [Daravel](https://pub.dev/packages/daravel),
di lima tabel milik [spatie/laravel-permission](https://spatie.be/docs/laravel-permission)
v6: aplikasi Laravel yang memakai Spatie dan aplikasi Daravel berbagi data
itu, dan role yang diberikan salah satunya terlihat oleh yang lain.

```bash
dart pub add daravel_permission
```

```dart
// bootstrap/app.dart
import 'package:daravel_permission/daravel_permission.dart';

Application createApp() => Application.configure(basePath: '.')
    .withPermissions()
    .withMigrations([...migrations, const CreatePermissionTables()])
    // ...
    .create();

final class User extends Model with AuthenticatableModel, HasRoles { /* ... */ }
```

```dart
await user.assignRole('writer');
await user.hasPermissionTo('posts.edit');
router.get('/admin', admin.index).middleware(['auth', 'role:admin|editor']);
```

- `HasRoles`, `Role`, dan `Permission` dengan method, exception, dan pesan
  403 dari Spatie; middleware `role`, `permission`, dan
  `role_or_permission`; hook gate, sehingga `Gate.allows` dan `can:`
  melihat permission.
- Guard, wildcard opsional (`posts.*`) dan role super-admin, serta perintah
  `permission:*`.
- Cache di memori: pengecekan berupa lookup set, dan perubahan sampai ke
  semua isolate dan proses (semua server, dengan cache store bersama) dalam
  satu detik.
- Diuji di SQLite, PostgreSQL, dan MariaDB, serta terhadap Laravel 12
  dengan Spatie 6.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/permissions.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. spatie/laravel-permission adalah paket berlisensi
MIT dari Spatie; Daravel hanya berbagi tata letak database-nya. Daravel
adalah proyek independen, tidak berafiliasi dengan dan tidak didukung oleh
pihak mana pun di atas.
