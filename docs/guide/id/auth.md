<!-- source: auth.md sha256:c481846da874 -->
# Autentikasi dan otorisasi

Guard didaftarkan di `bootstrap/app.dart`:

```dart
.withAuth((auth) {
  auth.token<User>('token', ModelUserProvider<User>(User.definition));
  auth.jwt<User>('jwt', ModelUserProvider<User>(User.definition));
})
```

Model memakai mixin `AuthenticatableModel`. `Auth.user()`, `Auth.id()`,
`Auth.check()`, dan `Auth.guard('jwt')` bekerja di mana saja di dalam
request, job, atau command; middleware `auth` (atau `auth:jwt`) menjawab 401
dengan `{"message": "Unauthenticated."}`.

## Personal access token (Sanctum)

```dart
final user = await Auth.retrieveByCredentials<User>({
  'email': email,
  'password': password,
});
if (user == null) {
  throw ValidationException.withMessages({'email': ['Invalid credentials.']});
}
final token = await Auth.issueToken(user, 'cli', abilities: ['posts:read']);
return {'token': token.plainTextToken, 'token_type': 'Bearer'};
```

Token memakai format dan tabel Sanctum 4: client menerima
`{id}|{40 karakter acak}{checksum crc32b}`, baris di `personal_access_tokens`
menyimpan SHA-256 dari semua bagian setelah `|`, dan `tokenable_type` adalah
kelas Laravel milik model (`App\Models\User`). Token yang dibuat Laravel bisa
dipakai login di Daravel, begitu juga sebaliknya. `SANCTUM_TOKEN_PREFIX`
menambahkan `token_prefix` Sanctum; `AUTH_TOKEN_EXPIRATION` (menit)
menetapkan masa berlaku global. `tokenCan`, `revokeCurrent`, `revokeAll`,
dan `sanctum:prune-expired` tersedia di `Auth.tokenGuard()`.

Bila tidak ada akun yang cocok dengan e-mail, password tetap di-hash
terhadap hash dummy, sehingga login yang gagal memakan waktu yang sama,
baik akunnya ada maupun tidak.

## JWT

`Auth.issueJwt(user)` menandatangani token HS256 dengan `JWT_SECRET` (atau
`APP_KEY`), atau EdDSA dengan `JWT_PUBLIC_KEY` / `JWT_PRIVATE_KEY`.
Verifikasi menolak `alg: none`, algoritma tanpa kunci yang dikonfigurasi,
tanda tangan yang salah, dan token kedaluwarsa; denylist mendukung logout.

## Hashing

`Hash.make` / `Hash.check` berjalan di compute isolate. Driver: `bcrypt`
(default, cost 12, `$2y$` seperti Laravel), `argon2id`, dan `pbkdf2`.
`Hash.check` mendeteksi driver dari hash-nya. Dengan `HASH_VERIFY=true`
(default), `Hash.check` menolak format asing kecuali keluarga yang kuat (bcrypt dan
argon2id), sehingga mengganti `HASH_DRIVER` di antara keduanya menjaga semua
password yang ada tetap valid, sementara `Hash.needsRehash` dan
`rehashPasswordIfRequired` meng-upgrade hash saat login. Tetap pakai bcrypt
selama aplikasi Laravel berbagi tabel users: secara default Laravel hanya
memverifikasi bcrypt.

## Enkripsi

`Crypt.encryptString` / `decryptString` menghasilkan payload Laravel
(`base64(json{iv, value, mac, tag})`) dengan kunci `APP_KEY`. Cipher-nya
adalah `APP_CIPHER`: `AES-256-CBC` (default, seperti Laravel;
encrypt-then-MAC dengan HMAC-SHA256) atau `AES-256-GCM`. Pakai nilai yang
sama dengan aplikasi Laravel mana pun yang berbagi data dengan Anda.
`APP_PREVIOUS_KEYS` memungkinkan rotasi kunci. `Crypt.encrypt` meng-encode
nilai ke JSON (Laravel memakai PHP `serialize()`), jadi hanya varian string
yang lintas runtime.

## Otorisasi

```dart
.withPolicies((gate) {
  gate.define('publish', (user, args) => user is User && user.isEditor);
  gate.policy<Post>(const PostPolicy());
})
```

`Gate.allows`, `Gate.denies`, `Gate.authorize` (403 dengan `This action is
unauthorized.`), dan middleware `can:update,post` bekerja seperti di
Laravel. Method policy default-nya `false`.
