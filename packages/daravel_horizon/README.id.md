<!-- source: README.md sha256:160bf9a0687c -->
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
queue menunggu di bawah setengah targetnya. Di antrean database, job yang
diambil kembali master dari worker yang crash menjadi tersedia lagi pada
saat itu, jadi waktu tunggunya dihitung sejak diambil kembali, bukan sejak
pertama kali di-push.

## API dashboard

`withHorizon(createApp: createApp)`
melayani API JSON dashboard di bawah `HORIZON_PATH` (`/horizon/api/...`)
dengan nama rute Laravel Horizon: statistik, beban kerja, master, tag yang
dimonitor, metrik job dan queue, job pending, completed, silenced, dan failed,
retry dan retry-all, serta `/horizon/api/stream` (statistik dan beban kerja
lewat server-sent events setiap detik). Retry-all (tambahan Daravel: Laravel
Horizon me-retry satu job sekali jalan) mendorong kembali paling banyak 1 000
job gagal atau sebanyak yang muat dalam 10 detik per request, lalu menjawab
berapa yang tersisa (`remaining`); dashboard memanggil lagi dengan `after` dan
`up_to` yang diterimanya sampai tidak ada yang tersisa. Retry-all yang sedang
berjalan membuat panggilan lain dijawab 409, dan job yang payload-nya tidak
terbaca tetap di `failed_jobs`, tercantum di `skipped`. Snapshot metrik diambil
oleh Horizon yang sedang berjalan: `dartisan horizon:snapshot` hanya
memintanya, jadi jadwalkan perintah itu setiap lima menit.

### Siapa yang boleh membukanya

Seperti Laravel Horizon, setiap request diotorisasi sesudah middleware-nya,
dan middleware saja tidak pernah membuka dashboard:

- `APP_ENV=local`: terbuka;
- selain itu `HorizonDashboard.auth(callback)` yang memutuskan bila dipasang;
- selain itu gate `viewHorizon`; tanpa gate, 403.

Callback atau gate yang melempar error menolak request itu, dan error-nya
dicatat di log. Tanpa `middleware:`, dashboard berada di belakang grup `web`
bila aplikasi memilikinya (`withSession()`), sehingga gate melihat user yang
sedang login:

```dart
gate.define('viewHorizon', (user, _) => user?.authIdentifier == 1);
```

Tanpa session tidak ada user; putuskan per request, misalnya dari header
rahasia yang ditambahkan proxy:

```dart
HorizonDashboard.auth(
  (request) =>
      constantTimeEquals(request.header('x-horizon-key') ?? '', horizonKey),
);
```

`middleware: ['web', 'auth']` mengarahkan tamu ke halaman login, bukan 403;
entri `middleware:` yang tidak didaftarkan aplikasi menghentikan boot. Di
belakang grup `web`, POST atau DELETE tanpa token XSRF (retry, monitoring)
dijawab 419 sebelum gate ditanya, seperti di Laravel.

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

Store `redis` (`HORIZON_STORE=redis`, dengan `withRedis()` dari
`daravel_redis`) menulis dalam batch yang sama, satu skrip Lua per batch.
Kuncinya diawali `REDIS_PREFIX` dan hash tag `{daravel:horizon}`: di Redis
Cluster semuanya berada di satu slot, jadi satu node menyimpan data Horizon,
dan kunci milik Laravel Horizon tidak pernah disentuh. Setiap kunci kecuali
himpunan tag yang dipantau kedaluwarsa sendiri, sehingga Redis bersih sendiri
bila Horizon berhenti. Daftar job menyimpan paling banyak
`HORIZON_STORE_MAX_PER_STATUS` job per status (10 000) di samping masa
simpannya, dan hitungan untuk rate, ringkasan, dan snapshot metrik disimpan
terpisah, sehingga tidak pernah terpotong oleh batas itu:

| Job per detik | Batas | Job selesai yang terdaftar | Memori Redis daftar, paling banyak |
| --: | --: | :-- | --: |
| 2 | 10 000 | satu jam penuh (7 200 job) | sekitar 15 MB |
| 10 | 10 000 | sekitar 17 menit | sekitar 15 MB |
| 1 000 | 10 000 | sekitar 10 detik | sekitar 15 MB |
| 1 000 | 100 000 | sekitar 100 detik | sekitar 40 MB |

Laravel Horizon mendaftar job selesai selama 60 menit tanpa batas jumlah
(gigabyte pada laju tinggi), dan store `database` juga tidak membatasi
jumlahnya. Sebuah record dihitung sekali per job dan status; hal itu diingat
bersama job-nya, sehingga duplikat yang datang setelah job keluar dari semua
daftar dihitung lagi.

## `retry_after`

Master membunuh worker yang terblok pada sebuah job satu heartbeat (minimal
satu detik) sebelum queue boleh memberikan job itu ke worker lain, pada saat
yang dinyatakan driver queue (`QueuedJob.reservedUntil`: detik bulat di queue
database, milidetik di Redis). Master dan worker-nya harus memakai
`QUEUE_RETRY_AFTER` yang sama; bila tidak, master memakai yang lebih awal dan
memberi peringatan. Worker memperpanjang reservasi job yang masih berjalan dan
memberi tahu master, yang mengikutinya: setiap setengah dari waktu yang
disisakan master untuk job itu, jadi `retry_after` kecil berarti penulisan
yang sering (3 detik di queue database: dua per detik per job yang berjalan).
Tidak tertutup: worker di proses atau host lain yang jamnya lebih cepat
(margin hanya menutupnya selama selisihnya lebih kecil dari margin), proses
yang ditangguhkan melewati reservasi, dan engine stream Redis pada jam server
yang berjalan cepat atau melompat maju.

## Lisensi

MIT.
