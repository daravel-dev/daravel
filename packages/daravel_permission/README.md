<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_permission

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_permission/README.id.md)

Roles and permissions in the database for [Daravel](https://pub.dev/packages/daravel),
on the five tables of [spatie/laravel-permission](https://spatie.be/docs/laravel-permission)
v6: a Laravel application using Spatie and a Daravel application share
them, and a role given by either is seen by the other.

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

- `HasRoles`, `Role` and `Permission` with Spatie's methods, exceptions and
  403 messages; the `role`, `permission` and `role_or_permission`
  middleware; a gate hook, so `Gate.allows` and `can:` see permissions.
- Guards, opt-in wildcards (`posts.*`) and super-admin role, and the
  `permission:*` commands.
- An in-memory cache: a check is a set lookup, and changes reach every
  isolate and process (every server, with a shared cache store) within a
  second.
- Tested on SQLite, PostgreSQL and MariaDB, and against Laravel 12 with
  Spatie 6.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/permissions.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. spatie/laravel-permission is Spatie's MIT-licensed
package; Daravel only shares its database layout. Daravel is an independent
project, not affiliated with or endorsed by any of them.
