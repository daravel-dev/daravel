<!-- source: sqlite-replication.md sha256:7ffd7d888d73 -->
# Replikasi SQLite

Container di Cloud Run, Fargate, atau Fly.io kehilangan disk-nya setiap
kali redeploy, begitu juga database SQLite di dalamnya. `dartisan
db:replicate` men-stream database ke sebuah disk storage (S3, R2, Google
Cloud Storage, atau bucket apa pun yang [kompatibel dengan S3](s3.md))
setiap kali berubah, seperti Litestream, dan `dartisan db:restore`
membangunnya kembali, misalnya saat container baru menyala. Restore
kehilangan paling banyak apa yang di-commit sejak sync terakhir, secara
default satu detik.

```bash
dart run bin/dartisan.dart db:replicate --disk=s3                 # sampai dihentikan
dart run bin/dartisan.dart db:restore --disk=s3 --if-missing      # saat container menyala
dart run bin/dartisan.dart db:replicas --disk=s3                  # isi replika
```

Database harus dalam WAL mode, yang sudah diatur oleh driver SQLite
Daravel. Replika disimpan di disk pada `replicas/<nama database>`
(`--path`).

## Cara kerjanya

Replicator mengambil snapshot database, lalu membaca write-ahead log saat
SQLite menulisnya, dan meng-upload frame yang sudah di-commit pada setiap
sync sebagai segmen kecil yang terkompresi:

```text
replicas/app/generations/20261029T081500123Z-1f2e3d4c/snapshot-1793268900123.db.gz
replicas/app/generations/20261029T081500123Z-1f2e3d4c/wal/0000000000-1793268901004.wal.gz
replicas/app/generations/20261029T081500123Z-1f2e3d4c/wal/0000000001-1793268902011.wal.gz
```

Sebuah snapshot dan segmen-segmen setelahnya membentuk sebuah *generasi*.
Restore mengambil snapshot generasi terbaru lalu menerapkan segmennya
secara berurutan.

Dua aturan menjaga replika tetap benar, apa pun yang dilakukan aplikasi
pada saat yang sama:

- **Hanya frame yang juga dipercaya SQLite yang di-upload:** frame dengan
  salt log saat ini, rantai checksum yang utuh, dan transaksi yang sudah
  lengkap di-commit. Transaksi yang masih ditulis menunggu commit-nya.
- **Bila replicator tidak bisa membuktikan bahwa semua frame sudah
  dibacanya, replicator memulai generasi baru** dengan snapshot baru. Ini
  terjadi bila log di-restart atau dipotong saat replicator tidak
  mengawasinya, misalnya saat `db:replicate` mati. Snapshot-nya identik per
  halaman (backup API SQLite), sehingga frame log tetap bisa diterapkan di
  atasnya.

Di antara dua sync, replicator memegang sebuah read transaction yang
mencegah SQLite me-restart log di bawahnya. Bila log mencapai
`--checkpoint-pages` frame (1000), replicator sendiri yang melipat log ke
database pada saat yang dikendalikannya, lalu mengikuti log baru tanpa
snapshot baru. Untuk itu replicator menulis satu baris di tabel
`_daravel_replication`, seperti Litestream dengan tabelnya sendiri. Setiap
`--snapshot-hours` (24) dibuat generasi baru agar jumlah yang diputar ulang
saat restore tetap terbatas, dan `--retain` (2) generasi disimpan.

## Restore

```bash
dart run bin/dartisan.dart db:restore --disk=s3                         # keadaan terbaru
dart run bin/dartisan.dart db:restore --disk=s3 --at=2026-10-29T08:00Z  # keadaan pada suatu waktu
dart run bin/dartisan.dart db:restore --disk=s3 --to=copy.sqlite        # ke lokasi lain
```

Hasil restore ditulis di samping target dan diperiksa dengan `PRAGMA
integrity_check` sebelum menggantikan apa pun, dan file yang sudah ada
tidak pernah diganti tanpa `--force`. Hentikan aplikasi sebelum memakai
`--force`. `--if-missing` tidak melakukan apa-apa bila database sudah ada,
cocok untuk perintah start sebuah container.

## Jaminan dan batasan

Suite tes menulis baris dengan id berurutan dari isolate lain, dengan
checkpoint di sela-selanya, dan melakukan restore sambil penulisan
berjalan. Setiap restore harus berupa prefix 1..k dari id tersebut, dan
restore terakhir harus sama dengan database. Suite ini juga mematikan
replicator, sebagai proses dengan SIGKILL dan sebagai isolate, lalu
memeriksa bahwa restore masih memuat setiap baris yang sudah
dikonfirmasinya.

- Satu replicator untuk satu database. Menjalankan dua tidak merusak apa
  pun, tetapi keduanya akan saling men-checkpoint log.
- Replika sama privatnya dengan disk-nya: pakai bucket privat. Snapshot
  dan segmen dikompresi, tidak dienkripsi; aktifkan server-side encryption
  pada bucket.
- Restore mengganti seluruh file; replika ini bukan read replica.
