<!-- source: README.md sha256:54201dbee5eb -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_reverb

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_reverb/README.md) · Bahasa Indonesia

Server protokol Pusher dari [Daravel](https://pub.dev/packages/daravel)
dalam proses tersendiri, mengikuti Laravel Reverb: `dartisan reverb:start`,
beberapa aplikasi dalam satu server, restart yang menyebar waktu reconnect
klien, dan statistik per isolate.

`withBroadcasting()` di `package:daravel` sudah melayani Laravel Echo dan
pusher-js di port HTTP; kebanyakan aplikasi tidak memerlukan lebih dari
itu. Pasang paket ini bila Anda memerlukan tier WebSocket tersendiri, atau
beberapa tenant dalam satu server. Format wire tetap Pusher 7, sehingga
Laravel Echo, pusher-js, dan broadcaster `pusher` Laravel terhubung sama
seperti ke Laravel Reverb.

```dart
// bootstrap/app.dart
import 'package:daravel_reverb/daravel_reverb.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withBroadcasting(channels: registerChannels)
    .withReverb(middleware: ['auth', 'can:viewReverb']) // dashboard /reverb
    .create();
```

```dart
// bootstrap/commands.dart
import 'package:daravel_reverb/commands.dart';

final List<CommandFactory> commands = [...reverbCommands];
```

`dartisan pub:add reverb` menuliskan keduanya.

## Perintah

| Perintah | |
| :-- | :-- |
| `reverb:start [--host] [--port] [--path] [--hostname] [--isolates] [--debug]` | Hanya melayani broadcasting aplikasi (`/app/{key}`, `/apps/{id}/*`, `/broadcasting/auth` dengan `REVERB_SERVER_AUTH=local`), `/up`, `/up/ready`, dan `/metrics`, dalam `REVERB_SERVER_ISOLATES` worker isolate. `--debug` mencatat setiap frame, dengan signature disamarkan tetapi isi event `client-*` dan broadcast apa adanya: untuk pengembangan, bukan produksi. |
| `reverb:restart` | Setiap isolate `reverb:start` yang memakai signal store queue yang sama (`QUEUE_SIGNAL_STORE`) menutup koneksinya tersebar dalam `REVERB_DRAIN_SPREAD` lalu berjalan lagi; klien reconnect dengan backoff masing-masing. Server satu isolate berhenti, agar process manager menjalankannya lagi, seperti di Laravel. |
| `reverb:stats [--url] [--token] [--json]` | Koneksi per isolate, channel dan pesan per aplikasi, dibaca dari `/metrics` server (`METRICS_ENABLED=true`). |

## Konfigurasi

| Variabel | Default | |
| :-- | :-- | :-- |
| `REVERB_SERVER_HOST`, `REVERB_SERVER_PORT`, `REVERB_SERVER_PATH` | `0.0.0.0`, `8080`, kosong | Alamat `reverb:start`; path menjadi prefix rute Pusher (`/ws`). |
| `REVERB_HOST` | | Nama host publik yang dicetak `reverb:start`. |
| `REVERB_SERVER_ISOLATES` | jumlah prosesor | Worker isolate `reverb:start`. |
| `REVERB_SERVER_AUTH` | `app` | `app`: aplikasi HTTP yang menjawab `/broadcasting/auth`; `local`: `reverb:start` juga menjawabnya, dengan guard yang sama. |
| `REVERB_APPS` | kosong | Daftar aplikasi dalam JSON, entri seperti di `config/reverb.php` Reverb: `app_id`, `key`, `secret`, `allowed_origins`, `max_connections`, `max_message_size`, `activity_timeout`, `rate_limiting` (`enabled`, `max_attempts`, `decay_seconds`, `terminate_on_limit`), ditambah `encryption_master_key` (base64). Aplikasi dari `REVERB_APP_*` dilayani di sampingnya. |
| `REVERB_APPS_PROVIDER` | `config` | `config` (`REVERB_APPS`) atau `database` (tabel `reverb_apps` dari `CreateReverbAppsTable`). |
| `REVERB_APPS_CACHE_TTL` | `60s` | Lama satu isolate menyimpan baris `reverb_apps`, ditemukan atau tidak. |
| `REVERB_METRICS_URL` | | `/metrics` dari server `reverb:start`, untuk dashboard `/reverb` aplikasi HTTP; kosong: `/metrics` aplikasi itu sendiri. |

Batas aplikasi `REVERB_APP_*`, `REVERB_DRAIN_SPREAD`, dan
`REVERB_PULSE_INGEST_INTERVAL` berasal dari `package:daravel`, seperti di
[panduan Broadcasting](https://daravel.dev/broadcasting.html). Pemeriksaan
konfigurasi melaporkan id atau key ganda dan origin yang bukan nama host,
serta memperingatkan secret di bawah 32 byte. `toMap()` (dan
`config:show`) tidak pernah memuat secret.

## Dashboard

`/reverb` (`withReverb(dashboard: '/reverb', middleware: [...])`) menampilkan koneksi
per aplikasi dan isolate, channel, pesan per detik, fan-out p50/p95,
penolakan dan slow consumer, daftar aplikasi tanpa secret-nya, dan tombol
untuk `reverb:restart`. Di luar `local` dan `testing`, halaman ini menjawab
403 sampai `middleware:` menjaganya. Definisikan gate di
`bootstrap/policies.dart`: `gate.define('viewReverb', (user, _) => ...)`.

## Beberapa aplikasi

Channel setiap aplikasi terpisah: klien satu aplikasi tidak pernah menerima
event aplikasi lain, dan signature yang dibuat dengan secret satu aplikasi
ditolak untuk aplikasi lain. Klien melihat nama channel biasa; di dalam
server, aplikasi selain aplikasi `REVERB_APP_*` dipisahkan dengan id-nya.

```dart
.withReverb(apps: ReverbApps.database()) // atau ReverbApps.fromEnv
```

## Lisensi

MIT.
