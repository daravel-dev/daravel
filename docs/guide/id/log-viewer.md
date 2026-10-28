<!-- source: log-viewer.md sha256:48351aab4d60 -->
# Log viewer

`daravel_log_viewer` menyajikan sebuah halaman, dari aplikasi Anda, yang
membaca file log-nya: entri terbaru lebih dulu, bisa difilter berdasarkan
level atau teks, stack trace tinggal satu klik, dan entri baru muncul saat
ditulis. File dibaca dari ujungnya, sehingga entri terakhir dari file
500 MB kembali dalam waktu kurang dari satu milidetik, dengan memori yang
sama seperti file kecil.

```bash
dart pub add daravel_log_viewer
```

```dart
// bootstrap/app.dart
import 'package:daravel_log_viewer/daravel_log_viewer.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withLogViewer(middleware: ['auth', 'can:view-logs'])
    // ...
    .create();
```

Halamannya ada di `/log-viewer` (`LOG_VIEWER_PATH`, atau
`withLogViewer(path: '/admin/logs')`). Halaman ini membaca folder tempat channel
log harian menulis (`LOG_PATH`, `storage/logs`), jadi tulis log ke file:

```dotenv
LOG_STACK=console,daily
```

## Siapa yang boleh melihat

Log mengungkap banyak hal tentang sebuah aplikasi. Di luar
`APP_ENV=local` dan `testing`, viewer menjawab 403 sampai `withLogViewer`
diberi middleware, misalnya `auth` dan sebuah gate:

```dart
// bootstrap/policies.dart
gate.define('view-logs', (user, args) => user is User && user.isAdmin);
```

`LOG_VIEWER_ENABLED=false` mematikannya (404) di mana pun.

## Yang ditampilkan

- **File.** Semua file `.log` di folder tersebut, terbaru lebih dulu,
  beserta ukurannya; file `daravel-YYYY-MM-DD.log` dari Daravel dan
  `laravel.log` dari aplikasi Laravel yang berbagi server sama-sama
  terbaca.
- **Entri.** Waktu, level, pesan; satu klik menampilkan context (sebagai
  JSON), error, dan stack trace, dengan frame aplikasi ditonjolkan
  dibanding frame framework dan SDK.
- **Level dan pencarian.** Chip level (`emergency` sampai `debug`) dan
  pencarian di seluruh isi entri: request id, user id, nama class
  exception.
- **Live.** Entri baru muncul saat ditulis, lewat server-sent events,
  dengan filter yang sama.
- **Entri lama.** Halaman berikutnya mundur menelusuri file tanpa
  membacanya dari awal.

Daravel menulis satu objek JSON per baris (`time`, `level`, `channel`,
`message`, `context`, `error`, `trace`); Laravel menulis baris Monolog
(`[2026-10-28 08:00:00] production.ERROR: ...`) diikuti stack trace.
Keduanya terbaca. Baris yang bukan kedua format itu ditampilkan apa
adanya.

## Data rahasia

Logger sudah mengganti nilai key `LOG_REDACT` saat entri ditulis. Viewer
juga menyembunyikan, sebelum entri keluar dari server, nilai key
`LOG_VIEWER_MASK_KEYS` (default `password`, `secret`, `token`,
`authorization`, `cookie`, `api_key`, `app_key`, `credit_card`, dicocokkan
sebagai bagian dari key, tanpa membedakan huruf besar-kecil): di context
pada kedalaman berapa pun, dan di teks seperti `password=...`,
`"token": "..."`, atau `Authorization: ...`.

Halaman ini tidak memuat apa pun dari host lain: script dan style-nya
inline, diizinkan oleh nonce baru di `Content-Security-Policy` yang tidak
mengizinkan apa pun selain itu, dan teks log selalu disisipkan sebagai
teks, tidak pernah sebagai HTML. Nama file harus file `.log` yang langsung
berada di folder tersebut: path, `..`, file tersembunyi, dan link yang
keluar dari folder dijawab 404.

## Pengaturan

| Variabel | Default | |
| :-- | :-- | :-- |
| `LOG_VIEWER_ENABLED` | `true` | `false` menjawab 404 |
| `LOG_VIEWER_PATH` | `/log-viewer` | URL halaman |
| `LOG_VIEWER_DIRECTORY` | `LOG_PATH` | folder file log |
| `LOG_VIEWER_PER_PAGE` | `50` | entri per halaman, maksimal 500 |
| `LOG_VIEWER_ALLOW_DOWNLOAD` | `true` | tombol Download |
| `LOG_VIEWER_ALLOW_DELETE` | `false` | tombol Delete (request `DELETE`) |
| `LOG_VIEWER_MASK_KEYS` | lihat di atas | key yang nilainya disembunyikan |
| `LOG_VIEWER_MAX_SCAN_MB` | `64` | seberapa banyak isi file yang dibaca satu halaman terfilter sebelum menawarkan untuk lanjut |

## API

Halaman ini memakai endpoint JSON di bawah path-nya, yang juga bisa
dipakai tool lain (di balik middleware yang sama):

| | |
| :-- | :-- |
| `GET /log-viewer/api/files` | daftar file, terbaru lebih dulu |
| `GET /log-viewer/api/entries?file=&levels=error,warning&search=&before=` | satu halaman entri, terbaru lebih dulu, dan `next`, nilai `before` untuk halaman yang lebih lama |
| `GET /log-viewer/api/tail?file=&levels=&search=` | event `entry` lewat server-sent events |
| `GET /log-viewer/api/download?file=` | file-nya |
| `DELETE /log-viewer/api/files?file=` | menghapus file (bila diizinkan) |

## File besar

`bench/bin/log_viewer_bench.dart` (build AOT, Windows 11, Dart 3.13.4):

| File | 50 entri terbaru | Pencarian yang tidak menemukan apa pun (membaca 64 MB) | Puncak memori |
| --: | --: | --: | --: |
| 100 MB | 0,8 ms | 1,2 s | 17 MB |
| 500 MB | 0,6 ms | 0,9 s | 17 MB |

Angka memori adalah puncak seluruh proses, termasuk runtime. Membaca satu
halaman atau mengikuti file hanya menyimpan satu blok 64 KB dan satu entri
setiap saat.
