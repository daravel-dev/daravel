# Daravel — Weekly Architecture & Implementation Reviews

Folder ini menyimpan catatan **Review, Masukan, Saran Perbaikan, dan Inovasi Mingguan** seiring berjalannya implementasi Daravel & `daragic`.

Setiap dokumen review mingguan mengevaluasi progres *tier* dan *slice* yang telah dikerjakan terhadap **tiga tujuan utama Daravel**:

1. **Ergonomi Laravel 11/12 + Jaminan Dart** — Single binary AOT (`dart compile exe`), static typing menyeluruh, konkurensi *Octane-grade* berbasis `Zone` + `Coordinator` isolate, dan *zero build-time magic* (tanpa `dart:mirrors` / `build_runner`).
2. **Koeksistensi *Side-by-Side* & Migrasi Dua Arah (`daragic`)** — Memungkinkan aplikasi Laravel dan Daravel berjalan berdampingan di atas database/infrastruktur yang sama serta bermigrasi dua arah secara bertahap dan terukur.
3. **Unifikasi Ekosistem Full-Stack Dart/Flutter** — Produktivitas backend sekelas Laravel dengan integrasi *end-to-end* untuk tim Dart & Flutter.

---

## Daftar Review Mingguan

| Minggu / Tanggal | Cakupan Tier & Slice | Dokumen | Status Tindak Lanjut |
| :--- | :--- | :--- | :--- |
| **Minggu 01** · `2026-10-24` | **Tier 0** (Walking Skeleton) & **Tier 1** (`S1`–`S12`) | [`2026-10-24-week-01-tier1-s12-review.md`](2026-10-24-week-01-tier1-s12-review.md) | 🚧 Open (Target: `S13`, `S14`, `S5b`) |

---

## Konvensi Penamaan & Struktur Review Mingguan

Setiap minggu, tambahkan file baru dengan format nama:

```text
docs/reviews/YYYY-MM-DD-week-XX-<ringkasan-scope>-review.md
```

Setiap dokumen review mingguan wajib memuat 5 bagian standar:

1. ** Evaluasi Progres Minggu Ini** — Apa yang sudah selesai dan sesuai dengan kontrak ADR di [`BLUEPRINT_V2.md`](../../BLUEPRINT_V2.md) dan [`BLUEPRINT_DARAGIC.md`](../../BLUEPRINT_DARAGIC.md).
2. ** Review Kritis & Temuan Celah** — Temuan teknis di kode yang berpotensi menghambat tujuan utama Daravel (koeksistensi Laravel, kesiapan `daragic`, keamanan, performa, atau DX).
3. ** Saran Perbaikan Konkret** — Rekomendasi teknis beserta lokasi file dan contoh perubahan API.
4. ** Ide Inovasi Strategis** — Usulan fitur atau kapabilitas bernilai tinggi (*unfair advantage*) untuk ekosistem Daravel.
5. ** Checklist Action Items (Target Minggu Berikutnya)** — Daftar tugas terukur dengan status `[ ]` / `[x]` yang akan ditinjau kembali pada review minggu berikutnya.
