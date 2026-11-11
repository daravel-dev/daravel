<!-- source: README.md sha256:2c8708eb5970 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_lints_plugin

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_lints_plugin/README.md) · Bahasa Indonesia

Rule [`daravel_lints`](https://pub.dev/packages/daravel_lints) di editor:
plugin analysis server Dart (`analysis_server_plugin`), sehingga temuan
`dartisan lint` muncul saat Anda mengetik, di VS Code, Android Studio dan
IntelliJ, juga di `dart analyze`.

Aktifkan di `analysis_options.yaml` proyek (bagian `plugins:` tingkat atas,
Dart 3.10 ke atas), lalu restart analysis server:

```yaml
plugins:
  daravel_lints_plugin: ^1.27.0
```

Rule yang dijalankan `dartisan lint` secara default langsung menyala. Rule
opt-in (`prefer_sql_identifier`) dinyalakan lewat namanya:

```yaml
plugins:
  daravel_lints_plugin:
    version: ^1.27.0
    diagnostics:
      prefer_sql_identifier: true
```

Temuan dibungkam seperti di `dartisan lint`
(`// daravel-lint-ignore: <rule>` di barisnya) atau dengan `// ignore: <rule>`
dari analyzer. Rule dan pemeriksaannya ada di `daravel_lints`; paket ini
hanya menjalankannya untuk analysis server, yang me-resolve paket ini
terpisah dari aplikasi Anda, sehingga `analyzer` yang di-pin paket ini tidak
pernah masuk ke dependency Anda.

## Mengerjakan rule

Analysis server membangun plugin di ruangnya sendiri dan me-resolve
dependency plugin di sana, dari pub.dev, walaupun `analysis_options.yaml`
menunjuk plugin dengan `path:`. Karena itu rule yang diubah di
`daravel_lints` repositori ini belum sampai ke editor sebelum dirilis, dan
plugin yang memakai API `daravel_lints` yang lebih baru gagal dibangun di
analysis server ("isn't defined"). Untuk mencoba rule yang belum dirilis,
override juga dependency plugin:

```yaml
plugins:
  daravel_lints_plugin:
    path: packages/daravel_lints_plugin
  dependency_overrides:
    daravel_lints:
      path: packages/daravel_lints
```

`dart test` di paket ini memakai `daravel_lints` dari workspace, sehingga
test menjaga kode yang sedang diubah. Untuk alasan yang sama, plugin yang
dirilis mensyaratkan `daravel_lints` dari rilisnya sendiri (`^<versi>`,
diperiksa oleh `tool/publish_checks.dart`), dan `daravel_lints` dirilis
lebih dulu.

## Biayanya

Diukur dengan `tool/editor_latency.dart` (analysis server lewat LSP,
seperti yang dijalankan editor, 10 edit per seri) di repositori Daravel,
workspace berisi sekitar tiga puluh paket, di Windows, dengan rule
`daravel_lints` 1.27.0 yang sudah terbit (lihat di atas):

- **Per edit: tidak terukur.** Temuan plugin tiba di pesan diagnostik yang
  sama dengan temuan analyzer: 15 sampai 21 ms (median) dengan plugin, 34
  sampai 35 ms tanpa plugin, yang masih dalam derau antarseri.
- **Memori: working set analysis server bertambah sekitar 430 sampai
  700 MB** (1,16 sampai 1,44 GB dengan plugin, 0,73 sampai 0,83 GB tanpa
  plugin). Plugin berjalan di isolate-nya sendiri dengan salinan
  analisisnya sendiri.
- **Start-up: puluhan detik setelah konfigurasi plugin berubah, beberapa
  detik bila tidak.** Start pertama setelah blok `plugins:` berubah
  (plugin diaktifkan, sumbernya atau `dependency_overrides` berubah)
  memakan 10 sampai 49 detik setelah analisis server sendiri, yang pertama
  kali bahkan lebih dari 30 detik; start dengan konfigurasi yang sama
  seperti run sebelumnya memakan 0,06 sampai 4,9 detik. Bergantian antara
  dua konfigurasi membuat setiap start lambat, dengan atau tanpa
  `dependency_overrides`.

Diukur lagi dengan rule repositori ini (`dependency_overrides` di atas,
setelah perubahan yang menelusuri setiap berkas sekali per rule): 17
sampai 29 ms per edit (median) dalam delapan seri, working set 1,17
sampai 1,68 GB, dan pola start-up yang sama. Satu seri sebelumnya dengan
148 ms, diambil saat mesin sibuk, diulang di mesin yang diam: 20 ms.

Workspace besar di mesin dengan memori kecil mungkin lebih baik mematikan
plugin dan menjalankan `dartisan lint`; rule-nya sama.

## Di CI

`dart analyze` juga menjalankan plugin, sehingga temuannya muncul di sana
sebagai `info`, dan `dart analyze --fatal-infos` gagal karenanya, sama
seperti `dartisan lint`. Job CI yang menjalankan keduanya melaporkan
setiap temuan dua kali, dan itu tidak berbahaya: keduanya gagal karenanya.
Tetap jalankan `dartisan lint` di CI, karena hanya `dartisan lint` yang
menjalankan pemeriksaan registry (`registry_entry_missing`); plugin tidak.
