# Roles and permissions

`daravel_permission` keeps roles and permissions in the database, on the
five tables of [spatie/laravel-permission](https://spatie.be/docs/laravel-permission)
v6, so a Laravel application using Spatie and a Daravel application can
share them: a role given by either is seen by the other.

```bash
dart pub add daravel_permission
```

```dart
// bootstrap/app.dart
import 'package:daravel_permission/daravel_permission.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withPermissions()
    .withMigrations([...migrations, const CreatePermissionTables()])
    // ...
    .create();
```

`CreatePermissionTables` creates `roles`, `permissions`, `model_has_roles`,
`model_has_permissions` and `role_has_permissions` with Spatie's columns,
keys and index names, and does nothing when `permissions` exists already,
so a database that ran Spatie's migration keeps it.

## The model

```dart
final class User extends Model with AuthenticatableModel, HasRoles {
  // ...
}
```

Assignments are stored under the model's morph class (`App\Models\User` by
default), as Laravel stores them.

```dart
final writer = await Role.create('writer');
await Permission.create('posts.edit');
await writer.givePermissionTo('posts.edit');

await user.assignRole('writer');            // a name, a Role, an id or a list
await user.givePermissionTo('posts.publish'); // directly, without a role

await user.hasRole('writer');               // also 'admin|writer'
await user.hasAnyRole(['admin', 'writer']);
await user.hasAllRoles(['admin', 'writer']);
await user.hasPermissionTo('posts.edit');   // through a role or directly
await user.getRoleNames();                  // ['writer']
await user.getAllPermissions();             // ['posts.edit', 'posts.publish']

await user.syncRoles(['editor']);           // replaces the roles
await user.removeRole('editor');
await user.revokePermissionTo('posts.publish');
```

As in Spatie, `hasPermissionTo` throws `PermissionDoesNotExist` for a
permission nobody could have (a typo), and `checkPermissionTo` answers
`false` instead. `Role.create` refuses a duplicate (`RoleAlreadyExists`),
and a role of another guard cannot be given (`GuardDoesNotMatch`); the
messages are Spatie's.

## Guards

Roles and permissions belong to a guard (`guard_name`). It is `web` unless
`PERMISSION_GUARD` says otherwise, since that is the name a Laravel
application uses, so the rows match. A model of another guard overrides
it:

```dart
final class Admin extends Model with AuthenticatableModel, HasRoles {
  @override
  String get guardName => 'admin';
}

await Role.create('admin', guard: 'admin');
```

## Gates and middleware

`withPermissions()` adds a gate hook, as Spatie's `Gate::before`: a
permission the user has makes `Gate.allows('posts.edit')`, the
`can:posts.edit` middleware and `authorize()` pass, and any other ability
goes on to your gate definitions and policies.

```dart
router.get('/admin', admin.index).middleware(['auth', 'role:admin|editor']);
router.post('/posts', posts.store).middleware(['auth', 'permission:posts.create']);
router.put('/posts/{id}', posts.update).middleware([
  'auth',
  'role_or_permission:admin|posts.edit',
]);
```

The names are separated by `|` (any of them); after a comma comes an auth
guard (`role:admin,token`). A refusal is a 403 with Spatie's messages:

```json
{"message": "User does not have the right roles."}
```

`PERMISSION_DISPLAY_ROLE_IN_EXCEPTION` and
`PERMISSION_DISPLAY_PERMISSION_IN_EXCEPTION` add the names to the message.

`PERMISSION_SUPER_ADMIN_ROLE=root` lets a role pass every gate check, the
pattern Spatie documents; it is off by default.

## Wildcards

With `PERMISSION_WILDCARD=true` (Spatie's `enable_wildcard_permission`),
permissions match by parts:

| Granted | Grants |
| :-- | :-- |
| `posts.*` or `posts` | `posts.edit`, `posts.edit.own` |
| `posts.edit,delete` | `posts.edit`, `posts.delete` |
| `posts.*.own` | `posts.edit.own`, not `posts.edit.all` |

## The cache

A model's roles and permissions are kept in memory after the first check,
so a check is a set lookup instead of three queries. A change made through
Daravel (`assignRole`, `givePermissionTo`, the commands, ...) applies at
once in its isolate and within a second on every other isolate and
process of the machine; with a cache store shared between servers
(`CACHE_STORE=database` or `redis`), on every server. A change made by a
Laravel application shows within `PERMISSION_CACHE_TTL` (5 minutes).

## Commands

Add them to `bootstrap/commands.dart`:

```dart
final List<CommandFactory> commands = [...permissionCommands];
```

| Command | What it does |
| :-- | :-- |
| `permission:create-role <name> [--guard] [--permissions=a,b]` | Creates a role, and gives it permissions |
| `permission:create-permission <name> [--guard]` | Creates a permission |
| `permission:assign <id> <role> [--model] [--guard]`, `permission:revoke ...` | Gives or takes a role (`--model` is the stored type, `App\Models\User` by default) |
| `permission:show [--guard]` | Roles against permissions |
| `permission:cache-reset` | Forgets the cached roles and permissions |

## With Laravel

`bench/interop/permission.sh` runs Laravel 12 with spatie/laravel-permission
6 and Daravel on one database: Laravel migrates and assigns, Daravel reads
it, Daravel assigns, Laravel reads it (`hasRole`, `can`). Teams
(`permission.teams`) and UUID model keys are not supported yet.
