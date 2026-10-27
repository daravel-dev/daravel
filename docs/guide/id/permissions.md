<!-- source: permissions.md sha256:479a028c0444 -->
# Role dan permission

`daravel_permission` menyimpan role dan permission di database, di lima
tabel milik [spatie/laravel-permission](https://spatie.be/docs/laravel-permission)
v6, sehingga aplikasi Laravel yang memakai Spatie dan aplikasi Daravel bisa
berbagi data itu: role yang diberikan salah satunya terlihat oleh yang lain.

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

`CreatePermissionTables` membuat `roles`, `permissions`, `model_has_roles`,
`model_has_permissions`, dan `role_has_permissions` dengan kolom, key, dan
nama index dari Spatie, dan tidak melakukan apa pun bila `permissions` sudah
ada, sehingga database yang sudah menjalankan migration Spatie tetap
memakainya.

## Model

```dart
final class User extends Model with AuthenticatableModel, HasRoles {
  // ...
}
```

Assignment disimpan dengan morph class model (`App\Models\User` secara
default), sama seperti cara Laravel menyimpannya.

```dart
final writer = await Role.create('writer');
await Permission.create('posts.edit');
await writer.givePermissionTo('posts.edit');

await user.assignRole('writer');            // nama, Role, id, atau list
await user.givePermissionTo('posts.publish'); // langsung, tanpa role

await user.hasRole('writer');               // juga 'admin|writer'
await user.hasAnyRole(['admin', 'writer']);
await user.hasAllRoles(['admin', 'writer']);
await user.hasPermissionTo('posts.edit');   // lewat role atau langsung
await user.getRoleNames();                  // ['writer']
await user.getAllPermissions();             // ['posts.edit', 'posts.publish']

await user.syncRoles(['editor']);           // mengganti role-nya
await user.removeRole('editor');
await user.revokePermissionTo('posts.publish');
```

Seperti di Spatie, `hasPermissionTo` melempar `PermissionDoesNotExist` untuk
permission yang tidak mungkin dimiliki siapa pun (salah ketik), sedangkan
`checkPermissionTo` menjawab `false`. `Role.create` menolak duplikat
(`RoleAlreadyExists`), dan role dari guard lain tidak bisa diberikan
(`GuardDoesNotMatch`); pesannya sama dengan pesan Spatie.

## Guard

Role dan permission dimiliki oleh sebuah guard (`guard_name`). Nilainya
`web` kecuali `PERMISSION_GUARD` menentukan lain, karena itulah nama yang
dipakai aplikasi Laravel, sehingga barisnya cocok. Model dengan guard lain
meng-override-nya:

```dart
final class Admin extends Model with AuthenticatableModel, HasRoles {
  @override
  String get guardName => 'admin';
}

await Role.create('admin', guard: 'admin');
```

## Gate dan middleware

`withPermissions()` menambahkan hook gate, seperti `Gate::before` milik
Spatie: permission yang dimiliki user membuat `Gate.allows('posts.edit')`,
middleware `can:posts.edit`, dan `authorize()` lolos, sedangkan ability lain
diteruskan ke definisi gate dan policy Anda.

```dart
router.get('/admin', admin.index).middleware(['auth', 'role:admin|editor']);
router.post('/posts', posts.store).middleware(['auth', 'permission:posts.create']);
router.put('/posts/{id}', posts.update).middleware([
  'auth',
  'role_or_permission:admin|posts.edit',
]);
```

Nama-namanya dipisah dengan `|` (salah satunya cukup); setelah koma
menyusul guard auth (`role:admin,token`). Penolakan berupa 403 dengan pesan
dari Spatie:

```json
{"message": "User does not have the right roles."}
```

`PERMISSION_DISPLAY_ROLE_IN_EXCEPTION` dan
`PERMISSION_DISPLAY_PERMISSION_IN_EXCEPTION` menambahkan nama-namanya ke
pesan.

`PERMISSION_SUPER_ADMIN_ROLE=root` membuat sebuah role lolos semua
pengecekan gate, pola yang didokumentasikan Spatie; secara default mati.

## Wildcard

Dengan `PERMISSION_WILDCARD=true` (`enable_wildcard_permission` dari
Spatie), permission dicocokkan per bagian:

| Diberikan | Mencakup |
| :-- | :-- |
| `posts.*` atau `posts` | `posts.edit`, `posts.edit.own` |
| `posts.edit,delete` | `posts.edit`, `posts.delete` |
| `posts.*.own` | `posts.edit.own`, bukan `posts.edit.all` |

## Cache

Role dan permission sebuah model disimpan di memori setelah pengecekan
pertama, sehingga pengecekan cukup berupa lookup set, bukan tiga query.
Perubahan lewat Daravel (`assignRole`, `givePermissionTo`, perintah CLI,
...) langsung berlaku di isolate-nya dan dalam satu detik di semua isolate
dan proses lain di mesin yang sama; dengan cache store yang dibagi
antarserver (`CACHE_STORE=database` atau `redis`), di semua server.
Perubahan yang dibuat aplikasi Laravel terlihat dalam
`PERMISSION_CACHE_TTL` (5 menit).

## Perintah

Tambahkan ke `bootstrap/commands.dart`, dari library tersendiri sehingga
server tidak ikut mengompilasi CLI:

```dart
import 'package:daravel_permission/commands.dart';

final List<CommandFactory> commands = [...permissionCommands];
```

| Perintah | Kegunaan |
| :-- | :-- |
| `permission:create-role <name> [--guard] [--permissions=a,b]` | Membuat role, dan memberinya permission |
| `permission:create-permission <name> [--guard]` | Membuat permission |
| `permission:assign <id> <role> [--model] [--guard]`, `permission:revoke ...` | Memberi atau mencabut role (`--model` adalah tipe yang disimpan, default `App\Models\User`) |
| `permission:show [--guard]` | Role terhadap permission |
| `permission:cache-reset` | Melupakan role dan permission yang di-cache |

## Bersama Laravel

`bench/interop/permission.sh` menjalankan Laravel 12 dengan
spatie/laravel-permission 6 dan Daravel di satu database: Laravel
menjalankan migration dan memberi role, Daravel membacanya, Daravel memberi
role, lalu Laravel membacanya (`hasRole`, `can`). Teams
(`permission.teams`) dan key model UUID belum didukung.
