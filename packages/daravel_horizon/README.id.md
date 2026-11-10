<!-- source: README.md sha256:0a6adf50944d -->
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

## Lisensi

MIT.
