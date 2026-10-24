# Authentication and authorization

Guards are registered in `bootstrap/app.dart`:

```dart
.withAuth((auth) {
  auth.token<User>('token', ModelUserProvider<User>(User.definition));
  auth.jwt<User>('jwt', ModelUserProvider<User>(User.definition));
})
```

The model mixes in `AuthenticatableModel`. `Auth.user()`, `Auth.id()`,
`Auth.check()` and `Auth.guard('jwt')` work anywhere inside a request, job or
command; the `auth` (or `auth:jwt`) middleware answers 401 with
`{"message": "Unauthenticated."}`.

## Personal access tokens (Sanctum)

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

Tokens use Sanctum 4's format and table: the client receives
`{id}|{40 random characters}{crc32b checksum}`, the `personal_access_tokens`
row stores the SHA-256 of everything after the `|`, and `tokenable_type` is
the model's Laravel class (`App\Models\User`). A token created by Laravel
authenticates in Daravel and the other way round. `SANCTUM_TOKEN_PREFIX`
adds Sanctum's `token_prefix`; `AUTH_TOKEN_EXPIRATION` (minutes) sets a
global lifetime. `tokenCan`, `revokeCurrent`, `revokeAll` and
`sanctum:prune-expired` are available on `Auth.tokenGuard()`.

When no account matches the e-mail, the password is still hashed against a
dummy hash, so a failed login takes the same time whether or not the account
exists.

## JWT

`Auth.issueJwt(user)` signs HS256 tokens with `JWT_SECRET` (or `APP_KEY`),
or EdDSA with `JWT_PUBLIC_KEY` / `JWT_PRIVATE_KEY`. Verification rejects
`alg: none`, algorithms without a configured key, bad signatures and expired
tokens; a denylist supports logout.

## Hashing

`Hash.make` / `Hash.check` run in a compute isolate. Drivers: `argon2id`
(default), `bcrypt` (`$2y$`, verifiable by PHP and Laravel) and `pbkdf2`.
`Hash.check` detects the driver from the hash, and `Hash.needsRehash` plus
`rehashPasswordIfRequired` upgrade hashes on login. When the database is
shared with Laravel, set `HASH_DRIVER=bcrypt` so Laravel can verify
passwords that Daravel writes.

## Encryption

`Crypt.encryptString` / `decryptString` produce Laravel's payload
(`base64(json{iv, value, mac, tag})`) keyed by `APP_KEY`. The cipher is
`APP_CIPHER`: `AES-256-GCM` (Daravel's default) or `AES-256-CBC`
(Laravel's default). Set it to match the Laravel app you share data with.
`APP_PREVIOUS_KEYS` enables key rotation. `Crypt.encrypt` JSON-encodes
values (Laravel uses PHP `serialize()`), so only the string variants are
cross-runtime.

## Authorization

```dart
.withPolicies((gate) {
  gate.define('publish', (user, args) => user is User && user.isEditor);
  gate.policy<Post>(const PostPolicy());
})
```

`Gate.allows`, `Gate.denies`, `Gate.authorize` (403 with `This action is
unauthorized.`) and the `can:update,post` middleware work like Laravel's.
Policy methods default to `false`.
