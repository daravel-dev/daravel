<!-- source: auth.md sha256:6e56a3a5b0ef -->
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

`{id}` pada token adalah key tabel: integer, seperti yang dibuat migration
Sanctum. Bila sisi Laravel memberi model `PersonalAccessToken` trait
`HasUuids` atau `HasUlids`, daftarkan guard dengan key yang sama, sehingga
token baru mendapat UUID atau ULID dan hanya id seperti itu yang dicari:
`auth.token<User>('token', provider, keyType: KeyType.uuid)`. Token yang
id-nya tidak mungkin menjadi key tabel ditolak sebelum database ditanya.

Bila tidak ada akun yang cocok dengan e-mail, password tetap di-hash
terhadap hash dummy, sehingga login yang gagal memakan waktu yang sama,
baik akunnya ada maupun tidak.

## JWT

`Auth.issueJwt(user)` menandatangani token HS256 dengan `JWT_SECRET` (atau
`APP_KEY`), atau EdDSA dengan `JWT_PUBLIC_KEY` / `JWT_PRIVATE_KEY`.
Verifikasi menolak `alg: none`, algoritma tanpa kunci yang dikonfigurasi,
tanda tangan yang salah, dan token kedaluwarsa.
`Auth.jwtGuard().invalidate()` mencabut token sampai kedaluwarsa (ditambah
leeway): denylist disimpan di cache store default, sehingga dengan
`CACHE_STORE=database` (atau Redis) semua mesin menolak token itu. Bila
cache store-nya ada di memori (`memory` atau `process`), id yang dicabut
mendapat store tersendiri di coordinator, sehingga semua worker isolate
menolak token itu dan key yang di-cache aplikasi tidak dapat
menggusurnya. Store itu menyimpan `JWT_DENYLIST_MAX_ENTRIES` id (100.000):
id yang kedaluwarsa dibuang lebih dulu, dan bila id yang masih berlaku
harus dibuang, server mencatat peringatan satu kali. Tentukan ukurannya
dari masa berlaku token dikali jumlah logout per detik, atau pakai
`database` atau Redis.

Aplikasi Laravel yang memakai tymon/jwt-auth (guard `jwt` dengan
`lock_subject`) dapat berbagi token dengan Daravel bila keduanya memakai
secret yang sama dan setelan berikut:

```dotenv
JWT_SECRET=<JWT_SECRET dari Laravel>
JWT_SUBJECT_CLASS=App\Models\User   # prv = sha1 dari nama class ini, seperti yang ditulis tymon
JWT_ISSUER_CLAIM=https://api.example.com   # iss untuk token yang diterbitkan (default APP_URL); wajib bagi tymon, tidak diperiksa
JWT_TTL=23040                       # menit, sama dengan ttl tymon
JWT_LEEWAY=0                        # detik, sama dengan leeway tymon
```

Token yang diterbitkan Laravel lalu dapat dipakai untuk login sebagai user
yang sama di Daravel, dan sebaliknya; `prv` untuk class model lain ditolak.

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

Di Linux, bcrypt dijalankan oleh library C milik sistem (`crypt_rn` dari
libxcrypt, implementasi yang juga dipakai PHP), sehingga biaya sebuah login
sama dengan di Laravel; di sistem lain, atau dengan
`DARAVEL_NATIVE_CRYPT=false`, implementasi Dart menghasilkan hash yang sama
sekitar 1,5 kali lebih lambat. Keduanya membaca hash `$2a$`, `$2b$`, dan
`$2y$`, dan memakai 72 byte pertama sebuah password, seperti PHP.

## Enkripsi

`Crypt.encryptString` / `decryptString` menghasilkan payload Laravel
(`base64(json{iv, value, mac, tag})`) dengan kunci `APP_KEY`. Cipher-nya
adalah `APP_CIPHER`: `AES-256-CBC` (default, seperti Laravel;
encrypt-then-MAC dengan HMAC-SHA256) atau `AES-256-GCM`. Pakai nilai yang
sama dengan aplikasi Laravel mana pun yang berbagi data dengan Anda.
`APP_PREVIOUS_KEYS` memungkinkan rotasi kunci. `Crypt.encrypt` membawa nilai
sebagai teks PHP `serialize()`, seperti `Crypt::encrypt` di Laravel: map atau
list yang dienkripsi di sini menjadi array di Laravel, dan sebaliknya (objek
PHP tiba sebagai `PhpObject`). Payload buatan Daravel 1.17 atau sebelumnya,
yang berisi JSON, tetap bisa didekripsi.

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

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `$user->currentAccessToken()->delete()` | `await Auth.tokenGuard().revokeCurrent()` | `TokenGuard.revokeCurrent` |  |
| `$user->tokenCan('posts:read')` | `await Auth.tokenGuard().tokenCan('posts:read')` | `TokenGuard.tokenCan` |  |
