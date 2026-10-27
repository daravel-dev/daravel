<!-- source: README.md sha256:e871ebb336b7 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_redis

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_redis/README.md) · Bahasa Indonesia

Redis dan Valkey untuk [Daravel](https://pub.dev/packages/daravel) di
beberapa server: cache dan lock bersama, rate limit dalam satu round trip,
queue yang menjalankan job begitu di-push, dan broadcasting antarserver. Di
satu server Daravel tidak membutuhkan semua ini; coordinator-nya menyimpan
state tersebut di memori.

```bash
dart pub add daravel_redis
```

```dart
// bootstrap/app.dart
import 'package:daravel_redis/daravel_redis.dart';

Application createApp() => Application.configure(basePath: '.')
    .withRedis()
    // ...
    .create();
```

```dotenv
REDIS_HOST=127.0.0.1       # atau REDIS_URL=rediss://user:secret@host:6380/0
REDIS_PASSWORD=
CACHE_STORE=redis          # cache, lock, denylist JWT
CACHE_LIMITER=redis        # rate limit
QUEUE_CONNECTION=redis     # job tanpa polling (BLPOP)
REVERB_SCALING_ENABLED=true
REVERB_SCALING_DRIVER=redis
```

- Berbicara RESP sendiri, dengan pipelining di satu koneksi per isolate,
  timeout per perintah, batas perintah yang menunggu balasan, dan TLS.
  Diuji di Redis 7 dan Valkey 8.
- Lock-nya adalah `RedisLock` dari Laravel (key, koneksi, skrip
  pelepasan), sehingga Laravel dan Daravel berbagi lock dengan
  `CACHE_PREFIX` yang sama. Queue tetap terpisah dari queue Laravel (key
  `daravel:`).
- `cache:clear` hanya menghapus key milik cache, tidak pernah seluruh
  database.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/redis.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; Redis adalah merek dagang Redis Ltd.; Valkey adalah
proyek dari Linux Foundation. Daravel adalah proyek independen, tidak
berafiliasi dengan dan tidak didukung oleh pihak mana pun di atas.
