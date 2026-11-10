<!-- source: README.md sha256:a09e3c4c0a96 -->
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

## Lisensi

MIT.
