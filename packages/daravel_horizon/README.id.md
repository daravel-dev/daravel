<!-- source: README.md sha256:5dd8ab83e05f -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_horizon

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_horizon/README.md) · Bahasa Indonesia

Supervisor queue untuk [Daravel](https://pub.dev/packages/daravel) seperti
Laravel Horizon: pool worker isolate per supervisor, ukurannya mengikuti
beban queue-nya, di tabel `jobs` yang sama dengan aplikasi Laravel.

> Masih dikerjakan. Rilis ini memuat konfigurasi dan auto-scaler;
> supervisor, perintahnya, dan dashboard menyusul.

```dart
import 'package:daravel_horizon/daravel_horizon.dart';

const plans = [
  SupervisorPlan(
    name: SupervisorName('supervisor-1'),
    queues: [QueueName('high'), QueueName('default')],
    minProcesses: 1,
    maxProcesses: 8,
  ),
];

final decision = decide(
  ScalingInput(
    plan: plans.first,
    queues: const [QueueLoad(queue: QueueName('high'), size: 120)],
  ),
  const ScalingState(workers: 1),
);
// decision.total, decision.perQueue, decision.shared
```

Auto-scaler adalah fungsi murni: per queue ia menghendaki
`ceil(Q·T / W + λ·T)` worker (Little's law pada laju kedatangan λ dan waktu
jalan T yang dihaluskan, W adalah target tunggu queue), membatasi jumlahnya
ke batas plan, bergeser paling banyak `balanceMaxShift` per evaluasi, dan
hanya mengurangi worker setelah dua evaluasi berturut-turut ketika setiap
queue menunggu di bawah setengah targetnya.

## API dashboard

`withHorizon(createApp: createApp, middleware: ['auth', 'can:viewHorizon'])`
melayani API JSON dashboard di bawah `HORIZON_PATH` (`/horizon/api/...`)
dengan nama rute Laravel Horizon: statistik, beban kerja, master, tag yang
dimonitor, metrik job dan queue, job pending, completed, silenced, dan failed,
retry dan retry-all, serta `/horizon/api/stream` (statistik dan beban kerja
lewat server-sent events setiap detik). Di luar `APP_ENV=local` dan `testing`,
API menjawab 403 sampai middleware melindunginya. Snapshot metrik diambil oleh
Horizon yang sedang berjalan: `dartisan horizon:snapshot` hanya memintanya,
jadi jadwalkan perintah itu setiap lima menit.

## Store

`HORIZON_STORE` menentukan tempat Horizon menyimpan job yang ditampilkannya,
hitungannya, tag yang dimonitor, dan snapshot:

| Store | Tempat | Untuk |
| :-- | :-- | :-- |
| `process` (bawaan) | coordinator proses yang menjalankan Horizon | satu proses: `serve --embed-worker=horizon`, atau `dartisan horizon --dashboard=:8090` |
| `database` | tabel `horizon_*` dari `CreateHorizonTables` (tambahkan ke daftar migrasi), pada `HORIZON_STORE_CONNECTION` | dashboard yang dilayani proses lain selain `dartisan horizon` |
| `redis` | `daravel_redis` (`withRedis()`) | sama, di Redis |

Store `database` menulis secara batch (setiap 250 ms atau 100 job), di luar
transaksi job, dan saat shutdown sebelum koneksi ditutup; record yang terpaksa
dibuang dihitung di `horizon_store_dropped_total`. Penulisan memangkas (paling
sering sekali per detik per store) baris yang melewati `HorizonConfig.trim`
(completed, failed, monitored);
`dartisan horizon:prune` memangkas semuanya, jalankan setiap hari. Di SQLite
store ini cocok untuk pengembangan: SQLite hanya punya satu penulis, jadi
untuk produksi dengan beberapa proses pakai PostgreSQL atau MySQL, atau
`redis`. Laravel Horizon menyimpan datanya di Redis dan tidak membuat tabel,
sehingga database yang dipakai bersama Laravel tidak punya tabel `horizon_*`
yang bisa bertabrakan.

## `retry_after`

Master membunuh worker yang terblok pada sebuah job satu heartbeat (minimal
satu detik) sebelum queue boleh memberikan job itu ke worker lain, pada saat
yang dinyatakan driver queue (`QueuedJob.reservedUntil`: detik bulat di queue
database, milidetik di Redis). Master dan worker-nya harus memakai
`QUEUE_RETRY_AFTER` yang sama; bila tidak, master memakai yang lebih awal dan
memberi peringatan. Tidak tertutup: worker di proses atau host lain yang
jamnya lebih cepat (margin hanya menutupnya selama selisihnya lebih kecil
dari margin), proses yang ditangguhkan melewati reservasi, job yang
memperpanjang reservasinya (`touch`), dan engine stream Redis pada jam server
yang berjalan cepat atau melompat maju.

## Lisensi

MIT.
