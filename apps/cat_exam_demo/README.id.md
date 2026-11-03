<!-- source: README.md sha256:1117fc63991e -->
# CAT Exam Demo

[English](README.md) · Bahasa Indonesia

Computer Assisted Test (CAT) yang dibangun dengan Daravel: peserta masuk di
satu perangkat, mengerjakan ujian berwaktu dengan jawaban yang tersimpan
saat dipilih, lalu langsung mendapat skor dan peringkat begitu selesai.
Formatnya mengikuti seleksi CPNS dengan tiga subtes: Tes Wawasan
Kebangsaan (TWK), Tes Inteligensia Umum (TIU), dan Tes Karakteristik
Pribadi (TKP). Halaman, pesan API, dan soalnya tersedia dalam bahasa
Inggris dan Indonesia.

| Fitur | Letaknya | Fitur Daravel yang dipakai |
| :-- | :-- | :-- |
| Satu perangkat per peserta, dengan reset oleh proctor | `ExamEngineService.verifyCandidateAndLock` | Model, transaksi |
| Soal dan pilihan diacak per peserta, kunci jawaban tidak pernah dikirim | `getQuestionsForSession` | `Random` dengan seed; bank soal di memori |
| Jawaban tersimpan di setiap klik, aman untuk dikirim ulang | `POST /api/exam/answer`, `idempotency_key` | Unique constraint, upsert `ExamAnswer` |
| Timer yang tidak bisa diubah client | `expires_at` diperiksa di server | `Clock.now()`, sehingga test bisa membekukan waktu |
| Skor seketika dan peringkat live | `finishExam`, `GET /api/exam/leaderboard` | Pengurutan query builder |
| Bahasa Inggris dan Indonesia | `lib/lang/`, `question_bank_en.dart` | `withTranslations`, `trans()`, `SetLocaleMiddleware` |

## Kebutuhan

- Dart SDK 3.13 atau lebih baru: `dart --version`. Repositori mengunci
  versinya di `.fvmrc`; dengan [fvm](https://fvm.app), tambahkan `fvm` di
  depan setiap perintah `dart` di bawah.
- Git dan browser. SQLite tidak perlu dipasang: paket `sqlite3` sudah
  membawanya.

## Menyiapkan

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # sekali, di root repositori

cd apps/cat_exam_demo
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # menulis APP_KEY ke .env
dart run bin/dartisan.dart migrate --seed # database/database.sqlite, 5 peserta, 15 soal
```

`dart pub get` dijalankan di root karena setiap contoh adalah anggota pub
workspace repositori: satu resolusi untuk semua paket.

## Menjalankan

```bash
dart run bin/dartisan.dart serve          # http://127.0.0.1:8000, Ctrl+C untuk berhenti
```

Ujian berlangsung selama `EXAM_DURATION_MINUTES` (30) dengan masa
toleransi `EXAM_GRACE_PERIOD_SECONDS` (15), keduanya di `.env`.

## Mencoba

Buka <http://127.0.0.1:8000> lalu pilih peserta demo:

| Peserta | NIK | Nomor peserta | Coba |
| :-- | :-- | :-- | :-- |
| Budi Santoso | `3201011203950001` | `TKA-2026-001` | Ujian lengkap: jawab, tandai ragu-ragu, selesaikan, lihat skor |
| Siti Rahmawati | `3201015508960002` | `TKA-2026-002` | Peserta kedua, untuk melihat peringkat |
| Ahmad Fauzi | `3201012211940003` | `TKA-2026-003` | Kunci perangkat: masuk di sini, lalu di browser lain (atau jendela private) dan muncul layar konflik; **Reset Kunci Perangkat** memerankan proctor |

Refresh halaman saat ujian berlangsung: sesi berlanjut dengan jawaban dan
sisa waktunya. **EN | ID** di header mengganti bahasa; API mengikutinya
lewat `Accept-Language`.

Alur yang sama dari terminal:

```bash
curl -s -X POST http://127.0.0.1:8000/api/exam/verify \
  -H 'Content-Type: application/json' \
  -d '{"nik": "3201011203950001", "exam_number": "TKA-2026-001", "device_id": "pc-1"}'
# {"status": "created", "token": "cat_...", ...}

curl -s http://127.0.0.1:8000/api/exam/questions -H 'Authorization: Bearer cat_...'
curl -s http://127.0.0.1:8000/api/exam/questions -H 'Authorization: Bearer cat_...' -H 'Accept-Language: id'
```

## API

| Route | Fungsinya |
| :-- | :-- |
| `POST /api/exam/verify` | Memasukkan peserta di satu perangkat: `created`, `resumed`, atau `completed`; `409 DEVICE_LOCK_CONFLICT` di perangkat lain |
| `GET /api/exam/session` | Sesi dan sisa waktunya |
| `GET /api/exam/questions` | Soal peserta, teracak, tanpa kunci jawaban |
| `POST /api/exam/answer` | Menyimpan satu jawaban; `410 EXAM_EXPIRED` setelah waktu habis |
| `POST /api/exam/batch-answers` | Menyimpan jawaban yang tertahan saat offline |
| `POST /api/exam/finish` | Mengakhiri ujian dan menilainya |
| `GET /api/exam/result/{sessionId}` | Lembar skor dan peringkat |
| `GET /api/exam/leaderboard` | Peringkat: total, lalu TKP, TIU, TWK, lalu yang mengumpulkan lebih dulu |
| `POST /api/exam/proctor/reset-lock` | Melepas kunci perangkat seorang peserta |

## Menjalankan test

```bash
dart test                                 # di apps/cat_exam_demo
```

21 test: perjalanan peserta lengkap, kunci perangkat, timer di server, 50
penyimpanan jawaban paralel, penilaian dan pemecahan nilai seri, kasus
tepi, serta kedua bahasa.

## Membangun binary native

```bash
dart build cli -t bin/server.dart -o build/cat_server
build/cat_server/bundle/bin/server        # .exe di Windows; butuh .env di sebelahnya
```

## Kalau ada masalah

| Gejala | Penyebab dan solusi |
| :-- | :-- |
| `pub get` menolak constraint SDK | Dart SDK lebih lama dari 3.13: perbarui, atau pakai `fvm dart` |
| `Address already in use` | Port 8000 dipakai program lain: ubah `APP_PORT` di `.env` |
| `APP_KEY is not set` | `.env` belum punya key: jalankan `key:generate` |
| `no such table: candidates` | Database belum di-migrate: jalankan `migrate --seed` |
| Peserta langsung melihat layar hasil | Peserta itu sudah selesai: jalankan `migrate:fresh --seed` (dengan `APP_ENV=local`) untuk mengulang |
| Windows: `Cannot delete file ... sqlite3.dll` saat test | Server yang sedang jalan memegang library SQLite: hentikan dulu, lalu jalankan test |

## Memakainya di luar repositori ini

Salin foldernya, hapus baris `resolution: workspace` dari `pubspec.yaml`,
ganti setiap constraint `any` pada paket Daravel dengan rilis terkini
(misalnya `^1.24.0`), lalu jalankan `dart pub get` di folder tersebut.

## Bagaimana aplikasi ini menghadapi awal ujian

Semua peserta dalam satu sesi masuk dalam beberapa menit yang sama, lalu
menyimpan jawaban setiap beberapa detik. Angka di bawah adalah hitungan
dari pola itu, bukan hasil pengukuran:

| | 20.000 peserta serentak | 100.000 peserta serentak |
| :-- | :-- | :-- |
| Login, tersebar dalam 3 menit | sekitar 110 per detik | sekitar 560 per detik |
| Penyimpanan jawaban, satu per peserta setiap 20 detik | sekitar 1.000 per detik | sekitar 5.000 per detik |
| Upload, sekitar 280 byte per penyimpanan | sekitar 2,2 Mbit/s | sekitar 11 Mbit/s |

Yang dilakukan kodenya untuk beban itu:

- Soal disajikan dari memori, jadi pengiriman soal tidak membaca database;
  hanya login, penyimpanan jawaban, dan penilaian yang menulis.
- Penyimpanan jawaban adalah satu upsert dengan kunci sesi dan soal, dan
  `idempotency_key` membuat request yang dikirim ulang tidak berbahaya.
- `dart run bin/dartisan.dart serve --isolates=N` menjalankan N worker
  isolate di satu port. Dengan lebih dari satu proses atau mesin, pakai
  PostgreSQL atau MySQL, bukan SQLite.

Untuk mengukur sebuah deployment, pakai benchmark harness di
[`bench/`](../../bench).

## Letak file

| Path | Isinya |
| :-- | :-- |
| `bootstrap/app.dart` | Aplikasi, terjemahan, dan middleware-nya |
| `routes/api.dart`, `routes/web.dart` | API dan halaman |
| `lib/app/services/exam_engine_service.dart` | Login, kunci perangkat, penyimpanan, timer, penilaian, peringkat |
| `lib/app/services/question_bank.dart`, `question_bank_en.dart` | Soal dalam bahasa Indonesia dan Inggris |
| `lib/lang/` | Baris terjemahan API dan halaman |
| `lib/resources/views/cat_exam_page.dart` | Halaman, HTML dan JavaScript biasa |
| `database/migrations/`, `database/seeders/` | Tabel dan peserta demo |
| `test/` | Test |
