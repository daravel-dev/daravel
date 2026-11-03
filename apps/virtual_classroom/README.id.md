<!-- source: README.md sha256:fd4cd25eb8b3 -->
# Kelas virtual (contoh)

[English](README.md) · Bahasa Indonesia

Aplikasi Daravel kecil yang menjadwalkan pelajaran dan menyelenggarakannya
di room video LiveKit: fitur yang biasanya ditambahkan platform sekolah saat
kelasnya pindah ke online. Aplikasi ini menunjukkan cara paket first-party
bekerja bersama dalam satu aplikasi, lengkap dengan halaman browser untuk
mencobanya:

| Paket | Dipakai untuk |
| :-- | :-- |
| `daravel_livekit` | Room setiap pelajaran, dan token bertanda tangan untuk tiap peserta |
| `daravel_google` | Pelajaran di Google Calendar sekolah, siswa sebagai tamu |
| `daravel_permission` | Role `teacher` dan `student`, middleware `role:teacher` |
| `daravel_teorion` | `?q=`, `?status=`, `?date=`, `?sort=` pada daftar pelajaran |
| `daravel_activitylog` | Siapa mengubah pelajaran mana, dan kapan |

Halaman dan pesan API tersedia dalam bahasa Inggris dan Indonesia: **EN | ID**
di header, atau lewat `Accept-Language`.

## Kebutuhan

- Dart SDK 3.13 atau lebih baru: `dart --version`. Repositori mengunci
  versinya di `.fvmrc`; dengan [fvm](https://fvm.app), tambahkan `fvm` di
  depan setiap perintah `dart` di bawah.
- Git, dan browser dengan kamera serta mikrofon untuk video.
- Untuk room video: **server LiveKit**. Ini layanan eksternal dan bukan
  bagian dari repositori ini; lihat [LiveKit](#livekit). Tanpa server itu,
  semuanya tetap jalan kecuali videonya.
- Untuk undangan kalender: **service account Google**, opsional; lihat
  [Google Calendar](#google-calendar).

## Menyiapkan

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # sekali, di root repositori

cd apps/virtual_classroom
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # menulis APP_KEY ke .env
dart run bin/dartisan.dart migrate --seed # satu guru, tiga siswa, pelajaran sepuluh menit lagi
```

Semua user hasil seed login dengan `password`: `teacher@example.com`, dan
`student1@example.com` sampai `student3@example.com`.

## LiveKit

LiveKit adalah server video yang dihubungi browser. Pasang dan jalankan di
luar repositori ini dengan salah satu cara berikut, dan jangan pernah
menyalin binary atau konfigurasinya ke folder aplikasi (`.gitignore`
menolaknya):

| Di mana | Caranya |
| :-- | :-- |
| Docker | `docker run --rm -p 7880:7880 -p 7881:7881 -p 7882:7882/udp livekit/livekit-server --dev --bind 0.0.0.0` |
| macOS | `brew install livekit`, lalu `livekit-server --dev` |
| Linux | `curl -sSL https://get.livekit.io \| bash`, lalu `livekit-server --dev` |
| Windows | Rilis dari [github.com/livekit/livekit/releases](https://github.com/livekit/livekit/releases), lalu `livekit-server.exe --dev` |
| LiveKit Cloud | Buat project, lalu salin URL, key, dan secret-nya ke `.env` |

`--dev` menjalankan server lokal dengan key `devkey` dan secret `secret`,
yang sudah tertulis di `.env.example` bersama
`LIVEKIT_URL=ws://127.0.0.1:7880`. Dengan LiveKit Cloud atau deployment
sendiri, isi `LIVEKIT_URL` (`wss://...`), `LIVEKIT_API_KEY`, dan
`LIVEKIT_API_SECRET`.

Kalau server berjalan di Docker di dalam WSL dan browser di Windows,
tambahkan `--node-ip 127.0.0.1` agar browser bisa menjangkau port media
lewat port forwarding WSL.

## Google Calendar

Opsional. Biarkan `GOOGLE_APPLICATION_CREDENTIALS` kosong dan pelajaran
dijadwalkan tanpa undangan; tampilan kalender di halaman lalu menunjukkan
apa yang akan dikirim.

Untuk mengirim undangan, buat service account di Google Cloud, bagikan
kalender sekolah kepadanya, unduh key JSON-nya **di luar repositori**, lalu
arahkan `.env` ke sana:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/path/di/luar/repo/service-account.json
GOOGLE_CALENDAR_ID=school@example.org
```

## Menjalankan

```bash
dart run bin/dartisan.dart serve          # http://127.0.0.1:8000, Ctrl+C untuk berhenti
dart run bin/dartisan.dart queue:work     # di terminal lain: undangan kalender
```

## Mencoba

1. Buka <http://127.0.0.1:8000>. Halaman otomatis masuk sebagai guru.
2. **Masuk LiveKit Room** pada pelajaran hasil seed. Browser meminta izin
   kamera dan mikrofon, lalu menampilkan Anda di room.
3. Buka tab kedua, klik **Siswa 1**, lalu masuk ke pelajaran yang sama:
   setiap tab melihat tab lainnya.
4. Sebagai siswa, **Angkat Tangan**: guru melihat ✋. Sebagai guru, **Mute
   Semua**: mikrofon siswa mati.
5. Klik **Orang Luar** lalu coba masuk: API menjawab 403.
6. **Jadwalkan Pelajaran Baru** sebagai guru, publikasikan atau jadikan
   draft, lalu lihat **Google Calendar** dan **Activity Log**.

Room dibuka 15 menit sebelum pelajaran dimulai dan ditutup saat pelajaran
selesai (409 di luar rentang itu). Tanpa server LiveKit, room menampilkan
pemberitahuan beserta token bertanda tangan yang tetap bisa Anda periksa.

## API

| Route | Siapa | Fungsinya |
| :-- | :-- | :-- |
| `POST /api/auth/login` | Semua | Bearer token untuk email dan password (5 percobaan per menit) |
| `GET /api/auth/me` | Sudah login | User saat ini dan role-nya |
| `GET /api/meetings` | Sudah login | Pelajaran di kelas milik user; siswa melihat yang published |
| `POST /api/classrooms/{classroom}/meetings` | Guru kelas tersebut | Menjadwalkan pelajaran; yang published dimasukkan ke kalender dengan siswa sebagai tamu |
| `GET /api/meetings/{id}` | Guru, siswa bila published | Satu pelajaran |
| `PATCH /api/meetings/{id}` | Guru | Menjadwal ulang, mempublikasikan, atau membatalkan publikasi; kalender ikut menyesuaikan |
| `DELETE /api/meetings/{id}` | Guru | Menghapus pelajaran beserta event kalendernya |
| `POST /api/meetings/{id}/join` | Guru, siswa bila published | `{url, room, token, expires_at, admin}` untuk client LiveKit |
| `POST /api/auth/demo-switch`, `GET /api/demo/state`, `GET /api/activity-logs` | Hanya demo | Pengalih akun dan panel samping di halaman |

Route demo memberi token tanpa password dan menampilkan semua user, jadi
hanya menjawab selama `APP_ENV` bernilai `local` atau `testing`, dan 404 di
tempat lain. Pertahankan `APP_ENV=production` di server.

Room bisa dimasuki mulai 15 menit sebelum pelajaran dan ditutup saat
pelajaran selesai; token tetap berlaku 15 menit setelahnya. Token guru
menjadikannya admin room; siswa bergabung dan mempublikasikan media. Angkat
tangan dan mute semua dikirim sebagai pesan data LiveKit, dan client hanya
menuruti perintah mute dari peserta yang token bertanda tangannya menyatakan
`teacher`.

## Dirancang untuk menit pertama kelas

Semua siswa sebuah sekolah bergabung di menit yang sama. Endpoint join
ditulis untuk itu:

- `CreateRoom` mengembalikan room bila sudah ada, sehingga siswa pertama dari
  sekian banyak siswa tidak perlu berebut membuatnya, dan tidak ada panggilan
  `ListRooms` di setiap join.
- Token ditandatangani di dalam request (HMAC, dalam hitungan mikrodetik);
  tidak ada yang menunggu kalender atau layanan lambat lain.
- `throttle:join` mengizinkan sepuluh percobaan per menit per user dan
  pelajaran, sehingga client yang mengulang dalam loop tidak menghabiskan
  kapasitas layanan room.
- Undangan kalender lewat queue setelah transaksi commit; Google API yang
  lambat atau gagal tidak pernah menunda atau menggagalkan request.

## Menjalankan test

```bash
dart test                                 # di apps/virtual_classroom
```

Test tidak membutuhkan LiveKit maupun Google: panggilan HTTP-nya dipalsukan
dan diperiksa.

## Kalau ada masalah

| Gejala | Penyebab dan solusi |
| :-- | :-- |
| Room menyatakan LiveKit tidak dapat dihubungi | Tidak ada server LiveKit di `LIVEKIT_URL`: jalankan (lihat [LiveKit](#livekit)) |
| Tersambung, tetapi tidak ada video antara Windows dan WSL | Jalankan server WSL dengan `--node-ip 127.0.0.1` |
| `409` saat join | Pelajaran di luar rentang room: jadwalkan dengan **Buka Room Sekarang** |
| `403` saat join | User bukan guru kelas itu dan bukan salah satu siswanya |
| Undangan kalender tidak terkirim | `GOOGLE_APPLICATION_CREDENTIALS` kosong, atau `queue:work` tidak berjalan |
| `APP_KEY is not set` | `.env` belum punya key: jalankan `key:generate` |
| Anda ingin database bersih | Hapus `database/database.sqlite`, lalu jalankan `migrate --seed` lagi |

## Memakainya di luar repositori ini

Salin foldernya, hapus baris `resolution: workspace` dari `pubspec.yaml`,
ganti setiap constraint `any` pada paket Daravel dengan rilis terkini
(misalnya `^1.24.0`), lalu jalankan `dart pub get` di folder tersebut.

## Membawanya ke aplikasi Laravel yang sudah ada

Tabelnya adalah tabel Laravel biasa. Aplikasi yang sudah punya data
pelajaran di Laravel bisa mengarahkan kode ini ke tabel `meetings` miliknya
sendiri (ganti nama kolom di model dan migration, atau lewati migration-nya),
memakai bersama `personal_access_tokens` dan tabel permission Spatie, lalu
memindahkan route pelajaran ke Daravel satu per satu di balik proxy, seperti
yang dijelaskan [Migrasi dari Laravel](../../docs/guide/id/migrating-from-laravel.md).
