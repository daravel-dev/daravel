<!-- source: teobiefy.md sha256:aaea7c9790c3 -->
# Teobiefy

`daravel_teobiefy` berbicara dengan protokol payload terenkripsi teobiefy
(v1) seperti yang diimplementasikan sebuah API Laravel, sehingga client web
dan mobile dari API tersebut bisa berkomunikasi dengan backend Daravel
tanpa perubahan satu baris pun, dan backend Laravel serta Daravel bisa
melayani client yang sama selama migrasi.

Protokolnya, seperti yang diimplementasikan aplikasi Laravel:

1. **Handshake.** Client mengirim public key X25519-nya ke
   `POST /api/v1/session-key`; server menjawab dengan public key-nya sendiri
   dan sebuah session id. Keduanya menurunkan sepasang kunci sesi
   (`crypto_kx` dari libsodium): server mendekripsi dengan `rx` apa yang
   dienkripsi client dengan `tx`-nya, dan sebaliknya.
2. **Request.** Body `{"data_enc": ..., "nonce": ...}` (ChaCha20-Poly1305
   IETF, base64) dengan header `X-Session-Id` didekripsi, lalu objek JSON-nya
   digabungkan ke input request.
3. **Response.** Field `data` dari jawaban JSON di-encode, dibungkus frame
   zstd, disegel dengan kunci `tx` sesi, lalu diganti dengan `data_enc` dan
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

`LIBSODIUM_STRICT_PAYLOAD=true` membuang key polos yang dikirim di samping
`data_enc` (aplikasi Laravel menggabungkannya, payload yang menang) dan
menjawab `406` untuk body polos dari client yang memegang sesi. Aktifkan
setelah semua client mengenkripsi semuanya; saat mati, perilakunya sama
dengan Laravel.

Nama-nama ini sama dengan yang dibaca aplikasi Laravel, sehingga satu `.env`
melayani keduanya.

## Sesi

`Teobiefy.handshake` memvalidasi `client_public_key` (base64 dari 32 byte,
selain itu `422`), menurunkan kuncinya, lalu menyimpannya di cache dengan
session id 64-hex acak selama `LIBSODIUM_SESSION_TTL` detik setelah setiap
pemakaian. Jawabannya berupa envelope obiefy/api-response, sama seperti
Laravel:

```json
{
  "status": 200,
  "message": "Sesi enkripsi berhasil dibuat.",
  "data": {"session_id": "…64 hex…", "server_public_key": "…", "expires_in": 1800},
  "data_count": 3
}
```

Session id bukan kredensial: session id hanya menunjuk pasangan kunci dan tidak
memberi hak apa pun. Autentikasi tetap dipegang guard di route. Handshake
memang terbuka (endpoint publik pun mengenkripsi), karena itu ada rate
limit.

Sesi disimpan di store cache default, atau di store `process` bila store
default menyimpan salinan per isolate: dengan beberapa worker, handshake
yang dijawab satu worker harus berlaku juga di worker lain. Pemeriksaan
replay menyimpan satu entri kecil per request terenkripsi di sana selama
TTL sesi, jadi ukurlah store untuk sesi ditambah request selama satu TTL:
store in-memory menampung 10.000 entri dan membuang yang paling lama tidak
dipakai di luar itu, yaitu sesi yang menganggur lebih lama dari sebanyak
itu request; Redis tidak punya batas seperti itu.

## Middleware

Pasang `teobiefy` di route yang payload-nya dienkripsi, sesuai daftar di
aplikasi Laravel.

- Request dengan `data_enc` didekripsi dengan kunci `rx` sesi, lalu objek
  JSON-nya digabungkan ke input (`request.merge`); `data_enc` dan `nonce`
  dihapus. Body yang gagal didekripsi dijawab `406 Invalid payload`,
  begitu pula body yang dikirim ulang: setiap nonce diingat selama sesi
  hidup (protokolnya tidak punya timestamp, jadi inilah pemeriksaan replay;
  aplikasi Laravel tidak memilikinya).
- Response JSON yang punya key `data` dienkripsi dengan kunci `tx` sesi.
  Key lain (`status`, `message`, `data_count`) tetap terbuka. Response tanpa
  `data`, dan apa pun yang bukan JSON, diteruskan apa adanya.
- Tanpa sesi dan tanpa legacy key, jawabannya `409` dengan
  `type: SESSION_KEY_REQUIRED`, tidak pernah data polos; client melakukan
  handshake ulang lalu mengulang request. Body polos dari client seperti
  itu ditolak sebelum handler berjalan, dan session id yang tidak dikenal
  store (kedaluwarsa, server lain) dijawab `409` meski legacy key aktif.

`LIBSODIUM_PAYLOAD_V2_ENABLED=true` menyegel byte zstd secara langsung dan
menambahkan `enc_v: 2`; client mengenalinya dari magic number zstd setelah
dekripsi. Aktifkan hanya setelah semua client mendukungnya, sama seperti di
Laravel.

Response berupa frame zstd dengan blok tersimpan (stored): semua decoder
zstd bisa membacanya (sudah dicek dengan `zstd` referensi), dan tidak butuh
library native, tetapi ukurannya tidak lebih kecil dari JSON-nya.

## Legacy key

`LIBSODIUM_LEGACY_KEY_ENABLED=true` menerima kunci statis lama untuk client
tanpa sesi. Kunci itu pernah terkirim ke browser dan harus dianggap publik:
ia hanya jembatan untuk frontend lama yang masih ter-cache selama rollout,
bukan perlindungan. Saat boot muncul warning selama kunci ini aktif, dan
boot gagal bila nilainya bukan kunci base64 32 byte.

## Envelope OpenSSL (`teobiefy.aes`)

Sebagian API Laravel tidak memakai libsodium, melainkan override
obiefy/api-response yang mengenkripsi `data` dengan OpenSSL dan kunci statis
(`App\Helpers\OpenSslHelper`):

```php
$key = base64_decode(config('openssl.openssl_key')); // 32 bytes
$iv = random_bytes(16);
$data = json_encode($json['data']);
$json['data_enc'] = base64_encode(openssl_encrypt($data, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv));
$json['iv'] = base64_encode($iv);
unset($json['data']);
```

`withTeobiefyAesCbc()` menambahkan envelope itu ke aplikasi Daravel:
AES-256-CBC dengan padding PKCS#7, kunci dari `OPENSSL_KEY` (base64 dari 32
byte, dengan atau tanpa `base64:`; boot gagal bila nilainya bukan kunci),
dan IV 16 byte acak per pesan. Pasang `teobiefy.aes` di route yang
dienkripsi aplikasi Laravel (aplikasi itu memutuskannya dari nama route,
`request()->routeIs('admin.user.login')`), dan `DecryptInterceptor` di
client membuka jawabannya seperti sebelumnya:

```dart
Application.configure(basePath: basePath).withTeobiefyAesCbc() // OPENSSL_KEY

router.post('/admin/v1/user/login', AuthController.login)
    .middleware(const ['teobiefy.aes']);
```

```json
{"status": 200, "message": "ok", "data_count": 1, "data_enc": "…base64…", "iv": "…base64…"}
```

- Tanpa parameter, `data` dari response objek JSON diganti dengan `data_enc`
  dan `iv`; key lain (`status`, `message`, `data_count`, `errors`) tetap
  terbuka, sebagaimana `OpenSslHelper` membiarkannya. Response JSON tanpa
  `data`, dan apa pun yang bukan JSON, diteruskan apa adanya; status code
  dan header dipertahankan.
- `teobiefy.aes:body` mengenkripsi seluruh body JSON, apa pun isinya,
  menjadi `{"data_enc": …, "iv": …}`.
- `teobiefy.aes:decrypt` juga membuka body request yang dikirim sebagai
  `{"data_enc": …, "iv": …}` dan menggabungkan objek JSON-nya ke input (key
  polos di sampingnya tetap ada, payload yang menang; `data_enc` dan `iv`
  dihapus). Body yang tidak bisa dibuka dijawab `406 Invalid payload`. Body
  polos tetap lolos: mode ini tidak bisa membedakan client tanpa kunci dari
  client yang memilih tidak mengenkripsi. Parameter bisa digabung:
  `teobiefy.aes:body,decrypt`.
- `teobiefy.aes:php` menulis teks polos dan envelope seperti `json_encode`
  PHP (slash di dalam `data_enc` dan `iv` di-escape, karakter non-ASCII
  menjadi escape), untuk client yang membandingkan atau menandatangani byte
  yang dikirim API Laravel.
- `TeobiefyAesCbc.current.encrypt(value)` dan `.decrypt(envelope)` melakukan
  hal yang sama secara manual (misalnya payload yang dibangun di job);
  `TeobiefyAesCbc.fromKey(key)` memberi cipher di luar container.

Implementasinya dicek terhadap NIST SP 800-38A (F.2.5, CBC-AES256) dan
terhadap `openssl enc`, library yang dipanggil sisi Laravel.

**Mode ini tidak punya MAC.** Kuncinya statis dan ikut terkirim bersama
client, jadi tidak menyembunyikan apa pun dari siapa pun yang memegang
client, dan tidak ada yang mencegah ciphertext yang diubah sampai ke
handler: blok yang diubah terdekripsi menjadi sampah atau, bila penyerang
beruntung, menjadi sesuatu yang bisa di-parse. Mode ini ada agar client
dari API yang di-port tetap berjalan; ini bukan perlindungan. Pekerjaan
baru, dan client tersebut begitu bisa diperbarui, sebaiknya memakai
protokol X25519 + ChaCha20-Poly1305 di atas.

## Bersama Laravel

Test-nya mengecek pertukaran kunci dan cipher terhadap vector yang dibuat
sodium PHP (libsodium): kunci sesi `crypto_kx` dan ChaCha20-Poly1305 IETF ke
dua arah. Perbedaannya:

- Body yang gagal didekripsi dijawab `406`. Middleware Laravel memanggil
  `api()->error(406, 'Invalid payload')`, yang argumennya adalah message dan
  data, sehingga menjawab `500` dengan `message: 406`.
- Kunci sesi disimpan dengan key yang dipakai Laravel
  (`libsodium:session-key:<id>`, array berisi `rx` dan `tx` base64). Di satu
  cache Redis dengan `REDIS_SERIALIZER=php` ([Redis](redis.md)) dan prefix
  cache yang sama, kedua aplikasi bisa membaca sesi satu sama lain (belum
  dicek end to end di sini). Store `database` di core membungkus nilai dalam
  JSON, sehingga lewat store itu tidak bisa: di belakang proxy yang
  mengirim client ke keduanya, client akan menerima `409` lalu handshake
  ulang.
- Response mana yang dienkripsi ditentukan oleh letak middleware, bukan
  oleh daftar nama route dan keyword relasi sensitif di Laravel.

Protokol v2 di blueprint (kunci diturunkan dari bearer token, tanda tangan
request) tidak diimplementasikan: kunci yang diturunkan dari token yang
ikut dikirim di request yang sama tidak melindungi apa pun yang belum
dilindungi koneksi TLS.

## Profil payload

teobiefy-laravel-api-response 0.3 mengganti session dengan profil per route.
`withTeobiefyProfiles()` menambahkan profil dan middleware
`teobiefy.profile`:

```dart
.withTeobiefyProfiles(
  keys: {'v1': env.string('TEOBIEFY_ENCRYPTION_KEY_V1')},
  responseProfiles: {'api/v1/exams/*': 'encrypted'},
  requestProfiles: {'api/v1/exams/*': 'encrypted'},
)
```

Pola dicocokkan dengan nama atau path route, seperti `route_profiles` di
`config/teobiefy.php`. `'teobiefy.profile:encrypted,plain'` pada route
menetapkan profil response dan request, seperti attribute `ResponseProfile`
dan `RequestProfile`. Profilnya adalah `plain`, `compressed`, `encrypted`,
`compressed_encrypted`, `signed`, dan `compressed_signed`.
`TEOBIEFY_ENCRYPTION_DRIVER` bernilai `xchacha20-poly1305`,
`chacha20-poly1305-ietf`, atau `aes-256-gcm`; `TEOBIEFY_ENCRYPTION_KEY`,
`TEOBIEFY_ENCRYPTION_ACTIVE_KID`, `TEOBIEFY_SIGNING_KEY`,
`TEOBIEFY_SIGNING_ACTIVE_KID`, dan `TEOBIEFY_REPLAY_PROTECTION` tetap memakai
nama yang sama.

Response berupa frame Zstandard dengan blok raw: semua decoder bisa membacanya,
tetapi ukurannya tidak mengecil. Request yang frame-nya memuat blok terkompresi
dijawab `406`, karena paket ini tidak punya entropy decoder.
