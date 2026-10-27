<!-- source: background.md sha256:4e39345fe57a -->
# Cache, event, queue, dan penjadwalan

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#cache-events-queue -->
```dart
final total = await Cache.remember(
  'posts.count',
  const Duration(minutes: 5),
  () => Post.query().count(),
);

await Event.dispatch(const PostPublished(1));
await Queue.dispatch(const PublishPost(1)).onQueue('posts');
```
<!-- /include -->

## Cache

Store: `memory` (per isolate, LRU), `process` (dibagi semua isolate server
melalui coordinator), `file`, dan `database` (tabel `cache` dari Laravel).
`Cache.remember`, `flexible` (stale-while-revalidate), `increment`, `pull`,
dan `lock` (atomic lock, gagal tertutup) mengikuti Laravel.

## Event

`Event.listen<OrderShipped>((event) async {...})` atau kelas listener di
`bootstrap/listeners.dart`. `Event.dispatchAfterCommit` menunggu transaksi
yang sedang berjalan. Listener yang di-queue berjalan melalui queue.

## Queue

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#job -->
```dart
final class PublishPost extends Job {
  const PublishPost(this.postId);

  final int postId;

  @override
  String get jobName => 'publish-post';

  @override
  Map<String, Object?> toJson() => {'post_id': postId};

  @override
  Future<void> handle(JobContext ctx) async {
    final post = await Post.query().findOrFail(postId);
    await post.update({'published': true});
  }
}
```
<!-- /include -->

Job didaftarkan berdasarkan nama di `bootstrap/jobs.dart`
(`JobDefinition('publish-post', (json) => PublishPost(...))`), karena
Daravel tidak memakai reflection. Driver: `sync`, `database` (tabel `jobs` /
`failed_jobs` dari Laravel), dan `memory`. Retry, backoff, timeout, unique
job, job middleware, `queue:work`, `queue:failed`, `queue:retry`, dan
`queue:restart` didukung. Dispatch di dalam transaksi secara default ditunda
sampai commit.

Worker yang menganggur menunggu paling lama `--sleep` (3 detik, seperti
Laravel) di antara polling yang kosong, tetapi push langsung
membangunkannya: di PostgreSQL queue database mengirim `NOTIFY` yang
didengar semua worker di semua mesin, dan queue memory membangunkan worker
di isolate-nya. Worker MySQL dan MariaDB melakukan polling seperti worker
Laravel.

`queue:work`, `queue:restart`, dan server adalah proses yang terpisah,
sehingga apa yang mereka bagi disimpan di luar ketiganya. Dengan queue
database, lock unique job disimpan di cache store `database` (tabel
`cache_locks` dari Laravel), dan sinyal `queue:restart` / `queue:pause` di
store `file`, yang menjangkau semua worker di mesin yang sama;
`QUEUE_SIGNAL_STORE=database` menjangkau worker di semua mesin.

Untuk monitoring dan operasional (hook yang menjadi dasar dashboard ala
Horizon):

- `List<String> get tags` pada job (misalnya `['user:42']`) disimpan di key
  `tags` pada payload.
- `Queue.connection().oldestWait('emails')` memberi tahu berapa lama job
  siap yang paling tua sudah menunggu.
- `dartisan queue:pause database:emails` menghentikan setiap worker
  mengambil job dari queue itu (job yang sedang berjalan tetap selesai)
  sampai `dartisan queue:continue database:emails`; `QueueWorker.pause()` /
  `resume()` melakukan hal yang sama untuk satu worker.

## Context

`Context` dari Laravel 11 menyimpan data tentang request, job, atau command
yang sedang berjalan. Entri yang terlihat ditambahkan ke setiap record log,
dan semuanya, termasuk entri tersembunyi, ikut terbawa ke job yang di-dispatch
dari sana:

```dart
// Sebuah middleware
Context.add('tenant_id', tenant.id);
Context.addHidden('api_token', token);    // ikut terbawa, tidak pernah di-log

// Nanti di request yang sama, atau di dalam job yang di-queue beberapa menit kemudian
final tenantId = Context.get<int>('tenant_id');
```

`addMany`, `addIf`, `push(key, [values])`, `has`, `forget`, `all()`, dan
padanan `…Hidden`-nya melengkapinya. Setiap request dimulai kosong. Nilainya
harus bisa di-encode ke JSON, seperti data job, dan nilai tersembunyi
disimpan di payload job (tabel `jobs`), jadi jangan taruh secret sungguhan
di sana.

## Penjadwalan

`routes/console.dart` mendeklarasikan jadwal:

```dart
void consoleRoutes(Schedule schedule) {
  schedule.command('reports:send').dailyAt('13:00').onOneServer();
  schedule.job(const PruneTokens()).hourly().withoutOverlapping();
}
```

Jalankan dengan `schedule:work` (berjalan terus) atau `schedule:run` dari
cron; `schedule:list` menampilkan jadwal berikutnya beserta zona setiap
task.

Ekspresi cron dibaca dalam `SCHEDULE_TIMEZONE` (`app.schedule_timezone`
dari Laravel), atau dalam UTC bila tidak di-set, kecuali sebuah task
menyebut zonanya sendiri. Laravel jatuh ke `APP_TIMEZONE`; Daravel 1.x
tidak, sehingga upgrade tidak pernah menggeser jadwal yang ada, dan
`dartisan doctor` memperingatkan bila `APP_TIMEZONE` bukan UTC sementara
`SCHEDULE_TIMEZONE` kosong. `schedule:list --timezone=Asia/Jakarta`
menampilkan jadwal berikutnya dalam zona itu.

```dart
schedule.command('reports:send').dailyAt('08:00').timezone('Asia/Jakarta');
schedule.job(const Digest()).dailyAt('09:00').timezone('America/New_York');
schedule.call(sync).hourly().timezone(const Duration(hours: 7)); // offset tetap
```

Zona IANA mengikuti daylight saving time seperti Laravel: waktu yang
terlewati saat jam dimajukan berjalan sebanyak itu lebih lambat (02:30
berjalan pukul 03:30), dan waktu yang berulang saat jam dimundurkan berjalan
dua kali. (Ini mengasumsikan perubahan jam paling banyak 3 jam dan berjarak
lebih dari 3 jam, seperti semua aturan DST saat ini; perubahan sekali jalan
seperti lompatan 24 jam Samoa pada 2011 bisa meleset satu kali.) Database
zona dikompilasi ke dalam biner (sekitar 0,5 MB, dengan nama alias yang
diterima PHP: `UTC`, `GMT`, `US/Eastern`, ...); nama zona yang tidak dikenal
melempar exception saat boot, dan `dartisan lint` melaporkannya
(`invalid_timezone`).
