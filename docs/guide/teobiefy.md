# Teobiefy

`daravel_teobiefy` speaks teobiefy's encrypted payload protocol (v1), as a
Laravel API implements it, so the web and mobile clients of that API talk
to a Daravel backend without a line of change, and a Laravel and a Daravel
backend can serve the same clients during a migration.

The protocol, as the Laravel application implements it:

1. **Handshake.** The client sends its X25519 public key to
   `POST /api/v1/session-key`; the server answers with its own and a
   session id. Both derive a pair of session keys (libsodium's `crypto_kx`):
   the server decrypts with `rx` what the client encrypted with its `tx`,
   and the other way round.
2. **Requests.** A body `{"data_enc": ..., "nonce": ...}` (ChaCha20-Poly1305
   IETF, base64) with the `X-Session-Id` header is decrypted and its JSON
   object merged into the request input.
3. **Responses.** The `data` of the JSON answer is encoded, zstd-framed,
   sealed with the session's `tx` key and replaced by `data_enc` and
   `nonce`.

```bash
dart pub add daravel_teobiefy
```

```dart
// bootstrap/app.dart
import 'package:daravel_teobiefy/daravel_teobiefy.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withTeobiefy()
    // ...
    .create();
```

```dart
// routes/api.dart
router.post('/v1/session-key', Teobiefy.handshake)
    .middleware(const ['throttle:30,1'])
    .name('session-key.store');

router.group(middleware: const ['jwt', 'teobiefy'], (r) {
  r.get('/profile', ProfileController.show);
  r.post('/evaluation-class-students/{id}', EvaluationController.update);
});
```

```dotenv
LIBSODIUM_SESSION_TTL=1800            # seconds a session lives after its last use
LIBSODIUM_PAYLOAD_V2_ENABLED=false    # true: seal the zstd bytes, enc_v: 2
LIBSODIUM_LEGACY_KEY_ENABLED=false    # the old static key; keep it false
LIBSODIUM_LEGACY_KEY=
LIBSODIUM_STRICT_PAYLOAD=false        # true: only the decrypted payload reaches the handler
```

`LIBSODIUM_STRICT_PAYLOAD=true` drops clear keys sent beside `data_enc`
(the Laravel application merges them, the payload winning) and answers
`406` to a clear body from a client that holds a session. Turn it on once
every client encrypts everything; off, the behaviour is Laravel's.

These are the names the Laravel application reads, so one `.env` serves
both.

## Sessions

`Teobiefy.handshake` validates `client_public_key` (base64 of 32 bytes,
else `422`), derives the keys and keeps them in the cache under a random
64-hex session id for `LIBSODIUM_SESSION_TTL` seconds after each use. The
answer is obiefy/api-response's envelope, as Laravel's:

```json
{
  "status": 200,
  "message": "Sesi enkripsi berhasil dibuat.",
  "data": {"session_id": "…64 hex…", "server_public_key": "…", "expires_in": 1800},
  "data_count": 3
}
```

The session id is not a credential: it names a key pair and grants
nothing. Authentication stays with the guard on the route. The handshake
is open by design (public endpoints encrypt too), hence the rate limit.

Sessions live in the default cache store, or in the `process` store when
the default keeps a copy per isolate: with several workers, a handshake
answered by one must hold on the others. The replay check keeps one small
entry per encrypted request there for the session TTL, so size the store
for the sessions plus the requests of one TTL: the in-memory stores hold
10 000 entries and drop the least recently used beyond that, which
would be sessions idle longer than that many requests; Redis has no such
cap.

## The middleware

Put `teobiefy` on the routes whose payloads are encrypted, as the Laravel
application lists them.

- A request with `data_enc` is decrypted with the session's `rx` key and
  its JSON object merged into the input (`request.merge`); `data_enc` and
  `nonce` are removed. A body that does not decrypt is `406 Invalid
  payload`, and so is a body sent again: each nonce is remembered for the
  session's lifetime (the protocol has no timestamp, so this is the replay
  check; the Laravel application has none).
- A JSON response with a `data` key is encrypted with the session's `tx`
  key. Other keys (`status`, `message`, `data_count`) stay in clear.
  Responses without `data`, and anything that is not JSON, pass as they
  are.
- Without a session and without the legacy key the answer is `409` with
  `type: SESSION_KEY_REQUIRED`, never plain data; the client handshakes
  again and repeats the request. A clear body from such a client is
  refused before the handler runs, and a session id the store does not
  know (expired, another server) is `409` even with the legacy key.

`LIBSODIUM_PAYLOAD_V2_ENABLED=true` seals the zstd bytes directly and adds
`enc_v: 2`; clients recognise it by zstd's magic number after decrypting.
Enable it only once every client does, as in Laravel.

Responses are zstd frames of stored blocks: every zstd decoder reads them
(checked with the reference `zstd`), and no native library is needed, but
they are not smaller than the JSON.

## The legacy key

`LIBSODIUM_LEGACY_KEY_ENABLED=true` accepts the old static key for clients
without a session. That key was shipped to browsers and must be treated as
public: it is a bridge for cached old frontends during a rollout, not a
protection. Boot warns while it is enabled and fails when it is not a
base64 32-byte key.

## The OpenSSL envelope (`teobiefy.aes`)

Some Laravel APIs do not use libsodium but an obiefy/api-response override
that encrypts `data` with OpenSSL and a static key (`App\Helpers\OpenSslHelper`):

```php
$key = base64_decode(config('openssl.openssl_key')); // 32 bytes
$iv = random_bytes(16);
$data = json_encode($json['data']);
$json['data_enc'] = base64_encode(openssl_encrypt($data, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv));
$json['iv'] = base64_encode($iv);
unset($json['data']);
```

`withTeobiefyAesCbc()` adds that envelope to a Daravel application: AES-256-CBC
with PKCS#7 padding, the key from `OPENSSL_KEY` (base64 of 32 bytes, with or
without `base64:`; boot fails when it is not a key) and a random 16-byte IV
per message. Put `teobiefy.aes` on the routes the Laravel application
encrypts (it decides by route name, `request()->routeIs('admin.user.login')`),
and the clients' `DecryptInterceptor` opens the answers as before:

```dart
Application.configure(basePath: basePath).withTeobiefyAesCbc() // OPENSSL_KEY

router.post('/admin/v1/user/login', AuthController.login)
    .middleware(const ['teobiefy.aes']);
```

```json
{"status": 200, "message": "ok", "data_count": 1, "data_enc": "…base64…", "iv": "…base64…"}
```

- Without parameters the `data` of a JSON object response is replaced by
  `data_enc` and `iv`; the other keys (`status`, `message`, `data_count`,
  `errors`) stay in clear, as `OpenSslHelper` leaves them. A JSON response
  without `data`, and anything that is not JSON, pass as they are; the
  status code and the headers are kept.
- `teobiefy.aes:body` encrypts the whole JSON body, whatever it is, into
  `{"data_enc": …, "iv": …}`.
- `teobiefy.aes:decrypt` also opens a request body sent as
  `{"data_enc": …, "iv": …}` and merges its JSON object into the input
  (clear keys beside it stay, the payload winning; `data_enc` and `iv` are
  removed). A body that does not open is `406 Invalid payload`. Clear
  bodies still pass: this mode cannot tell a client without the key from
  one that chose not to encrypt. Parameters combine: `teobiefy.aes:body,decrypt`.
- `teobiefy.aes:php` writes the clear text and the envelope as PHP's
  `json_encode` does (escaped slashes inside `data_enc` and `iv`, non-ASCII
  as escapes), for clients that compare or sign the bytes a Laravel API
  sent.
- `TeobiefyAesCbc.current.encrypt(value)` and `.decrypt(envelope)` do the
  same by hand (a payload built in a job, say); `TeobiefyAesCbc.fromKey(key)`
  gives a cipher outside the container.

The implementation is checked against NIST SP 800-38A (F.2.5, CBC-AES256)
and against `openssl enc`, the library the Laravel side calls.

**This mode has no MAC.** The key is static and was shipped with the
clients, so it hides nothing from whoever has a client, and nothing stops
an altered ciphertext from reaching the handler: an altered block decrypts
to garbage or, with luck for the attacker, to something that parses. It
exists so the clients of a ported API keep working; it is not a protection.
New work, and those clients once they can be updated, belong on the X25519
+ ChaCha20-Poly1305 protocol above.

## With Laravel

The tests check the key exchange and the cipher against vectors made by
PHP's sodium (libsodium): the session keys of `crypto_kx` and
ChaCha20-Poly1305 IETF both ways. Differences:

- A body that does not decrypt answers `406`. The Laravel middleware calls
  `api()->error(406, 'Invalid payload')`, whose arguments are a message and
  data, and so answers `500` with `message: 406`.
- Session keys are stored under the key Laravel uses
  (`libsodium:session-key:<id>`, an array of base64 `rx` and `tx`). On one
  Redis cache with `REDIS_SERIALIZER=php` ([Redis](redis.md)) and the same
  cache prefix, both applications can read each other's sessions (not
  checked end to end here). The core `database` store wraps values in JSON,
  so through it they cannot: behind a proxy that sends a client to both,
  the client meets a `409` and handshakes again.
- Which responses are encrypted is decided by where the middleware is, not
  by Laravel's list of route names and sensitive relation keywords.

The blueprint's protocol v2 (keys derived from the bearer token, request
signatures) is not implemented: a key derived from a token that travels
in the same request protects nothing the TLS connection does not.

## Payload profiles

teobiefy-laravel-api-response 0.3 replaces the session with a profile per
route. `withTeobiefyProfiles()` adds them and the `teobiefy.profile`
middleware:

```dart
.withTeobiefyProfiles(
  keys: {'v1': env.string('TEOBIEFY_ENCRYPTION_KEY_V1')},
  responseProfiles: {'api/v1/exams/*': 'encrypted'},
  requestProfiles: {'api/v1/exams/*': 'encrypted'},
)
```

Patterns match a route name or path, as `route_profiles` in
`config/teobiefy.php`. `'teobiefy.profile:encrypted,plain'` on a route sets
the response and request profiles, as the `ResponseProfile` and
`RequestProfile` attributes. The profiles are `plain`, `compressed`,
`encrypted`, `compressed_encrypted`, `signed` and `compressed_signed`.
`TEOBIEFY_ENCRYPTION_DRIVER` is `xchacha20-poly1305`,
`chacha20-poly1305-ietf` or `aes-256-gcm`; `TEOBIEFY_ENCRYPTION_KEY`,
`TEOBIEFY_ENCRYPTION_ACTIVE_KID`, `TEOBIEFY_SIGNING_KEY`,
`TEOBIEFY_SIGNING_ACTIVE_KID` and `TEOBIEFY_REPLAY_PROTECTION` keep their
names.

Responses are Zstandard frames of raw blocks: every decoder reads them, but
they are not smaller. A request whose frame has compressed blocks answers
`406`, because this package has no entropy decoder.
