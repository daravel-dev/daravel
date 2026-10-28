# Kelas virtual (contoh)

[English](README.md) · Bahasa Indonesia

Aplikasi Daravel kecil yang menjadwalkan pelajaran dan menyelenggarakannya
di room video LiveKit: fitur yang biasanya ditambahkan platform sekolah saat
kelasnya pindah ke online. Aplikasi ini menunjukkan cara paket first-party
bekerja bersama dalam satu aplikasi:

| Paket | Dipakai untuk |
| :-- | :-- |
| `daravel_livekit` | Room setiap pelajaran, dan token bertanda tangan untuk tiap peserta |
| `daravel_google` | Pelajaran di Google Calendar sekolah, siswa sebagai tamu |
| `daravel_permission` | Role `teacher` dan `student`, middleware `role:teacher` |
| `daravel_teorion` | `?q=`, `?status=`, `?date=`, `?sort=` pada daftar pelajaran |
| `daravel_activitylog` | Siapa mengubah pelajaran mana, dan kapan |

## API

Setiap route membutuhkan bearer token (`auth`).

| Route | Siapa | Fungsinya |
| :-- | :-- | :-- |
| `GET /api/meetings` | Semua | Pelajaran di kelas user; siswa melihat yang sudah dipublikasikan |
| `POST /api/classrooms/{classroom}/meetings` | Guru kelas tersebut | Menjadwalkan pelajaran; yang dipublikasikan dimasukkan ke kalender dengan siswa sebagai tamu |
| `GET /api/meetings/{id}` | Guru, siswa bila sudah dipublikasikan | Satu pelajaran |
| `PATCH /api/meetings/{id}` | Guru | Menjadwal ulang, mempublikasikan, atau membatalkan publikasi; kalender ikut berubah |
| `DELETE /api/meetings/{id}` | Guru | Menghapus pelajaran dan event kalendernya |
| `POST /api/meetings/{id}/join` | Guru, siswa bila sudah dipublikasikan | `{url, room, token, expires_at, admin}` untuk client LiveKit |

Room bisa dimasuki 15 menit sebelum mulai dan tertutup saat pelajaran
selesai; token tetap berlaku 15 menit setelah selesai. Token guru menjadikan
guru admin room (mematikan suara, mengeluarkan peserta); siswa bergabung dan
mempublikasikan video.

## Dirancang untuk menit pertama kelas

Semua siswa satu sekolah masuk di menit yang sama. Endpoint join ditulis
untuk itu:

- `CreateRoom` mengembalikan room bila sudah ada, sehingga siswa pertama
  tidak perlu berebut membuatnya, dan tidak ada panggilan `ListRooms` di
  setiap join.
- Token ditandatangani di dalam request (HMAC, mikrodetik); tidak ada yang
  menunggu kalender atau layanan lambat lain.
- `throttle:join` mengizinkan sepuluh percobaan per menit per user dan
  pelajaran, sehingga client yang mencoba ulang terus-menerus tidak
  menghabiskan kapasitas room service.
- Undangan kalender dikirim lewat queue setelah transaksi commit; Google API
  yang lambat atau gagal tidak pernah menunda atau menggagalkan request.

## Menjalankan

```bash
cp .env.example .env
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart migrate --seed     # satu guru, tiga siswa, pelajaran sepuluh menit lagi
livekit-server --dev &                        # LIVEKIT_API_KEY=devkey, LIVEKIT_API_SECRET=secret
dart run bin/dartisan.dart serve
dart run bin/dartisan.dart queue:work         # undangan kalender
```

`dart test` menjalankan test fitur tanpa LiveKit atau Google: panggilan
HTTP ke keduanya dipalsukan dan diperiksa.

## Menerapkan pada aplikasi Laravel yang sudah ada

Tabelnya adalah tabel Laravel biasa. Aplikasi yang sudah menyimpan
pelajaran di Laravel bisa mengarahkan kode ini ke tabel `meetings`-nya
sendiri (ubah nama kolom di model dan migration, atau lewati migration),
berbagi `personal_access_tokens` dan tabel permission Spatie, lalu
memindahkan route pelajaran ke Daravel satu per satu di belakang proxy,
seperti dijelaskan di
[Migrasi dari Laravel](../../docs/guide/id/migrating-from-laravel.md).
