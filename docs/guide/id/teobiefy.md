<!-- source: teobiefy.md sha256:f3a6f5bc4f6a -->
# Teobiefy

`daravel_teobiefy` berbicara dengan protokol payload terenkripsi dari API
Laravel Bali Melajah (teobiefy, protokol v1), sehingga client web dan
mobile-nya bisa berkomunikasi dengan backend Daravel tanpa perubahan satu
baris pun, dan backend Laravel serta Daravel bisa melayani client yang sama
selama migrasi.

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
