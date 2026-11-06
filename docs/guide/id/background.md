<!-- source: background.md sha256:a90cd9648da6 -->
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
Di store `process`, lock yang diberikan coordinator setelah jawabannya
timeout langsung dilepas alih-alih tertahan sampai TTL-nya habis, dan
`lock.block` menganggap percobaan itu tidak berhasil lalu mencoba lagi.
`Cache.tags(['people', 'artists']).put(...)` memberi tag pada entri dan
`Cache.tags(['people']).flush()` melupakannya, di store `memory` dan
`process` serta dengan [Redis](redis.md#cache-tags), dengan key yang sama
seperti Laravel; `file` dan `database` tidak bisa memberi tag, seperti di
Laravel.

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

### Percobaan, timeout, dan `retry_after`

- `tries` menghitung setiap reservasi, termasuk release oleh middleware
  (`WithoutOverlapping`, `RateLimitedJob`) atau `ctx.release()`. Job yang
  direservasi lagi setelah percobaan terakhirnya gagal dengan
  `MaxAttemptsExceededException` tanpa dijalankan, seperti di Laravel, begitu
  pula job yang direservasi setelah `retryUntil`-nya lewat; job yang
  di-release sampai sebuah lock bebas membutuhkan `tries` (atau `retryUntil`)
  yang mencakup waktu tunggu itu. `int? get maxExceptions` menggagalkan job
  setelah exception sebanyak itu, berapa pun sisa percobaannya.
- Dart tidak bisa menghentikan future yang sedang berjalan, sehingga handler
  yang melewati `timeout`-nya tetap berjalan. `ctx.cancelled`-nya di-set, dan
  handler itu berjalan dengan `ctx.cancellation` sebagai
  `CancellationToken.current`: `DB.transaction` yang masih dijalankannya
  di-rollback dengan `OperationCancelledException` alih-alih di-commit, dan
  `WithoutOverlapping` menahan lock-nya sampai `expiresAfter`. Worker yang
  job-nya timeout lalu di-release berhenti dengan exit code 1 (`queue:work`
  mengakhiri prosesnya), sehingga process manager menjalankan worker baru.
- Error asinkron yang dibiarkan tidak tertangkap oleh handler (future yang
  tidak di-await) menggagalkan percobaan setelah handler selesai, tidak
  pernah selagi handler masih berjalan.
- Queue database dan Redis menyerahkan job yang direservasi ke worker lain
  setelah `QUEUE_RETRY_AFTER` (90 detik). Selama job berjalan, worker
  memperpanjang reservasinya setiap setengah `retry_after`, sehingga job yang
  lama tidak dijalankan dua kali sekaligus; job dari worker yang berhenti
  merespons menunggu `retry_after`. Seperti di Laravel, jaga
  `QUEUE_RETRY_AFTER` di atas `timeout` job yang paling lama: worker
  memperingatkan bila timeout sebuah job (atau `--timeout`) tidak di
  bawahnya.
- `Queue.dispatch(job)` mem-push job meskipun tidak ada yang meng-await-nya
  (dalam microtask, setelah setter yang dirangkai padanya), seperti Laravel
  mem-push `PendingDispatch` saat keluar dari scope. Meng-await-nya memberi
  id job atau error dari push; push yang gagal dan tidak di-await dicatat ke
  log.

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

Bila pembukuan worker sendiri gagal, job tidak hilang dan worker tidak
berhenti:

- Listener `JobProcessing`, `JobProcessed`, `JobExceptionOccurred`, atau
  `JobFailed` yang melempar exception dicatat ke log; job tetap dihapus,
  di-release, atau dicatat sebagai gagal, dan unique lock-nya dilepas.
- Bila database atau cache gagal (worker yang dijalankan saat outage, signal
  store di disk yang penuh), worker mencatat error pertama beserta stack
  trace-nya lalu paling banyak satu per menit, menunggu lebih lama di antara
  polling (`--sleep`, dua kali lipat setelah setiap error berikutnya, paling
  lama satu menit, dengan jitter), dan melanjutkan begitu keduanya pulih.
  Flag `queue:pause` yang tidak bisa dibaca dianggap tidak di-pause. Di
  PostgreSQL, `LISTEN` yang tidak bisa dibuka, atau yang terputus, dibuka
  lagi 30 detik kemudian (`DatabaseQueue(listenRetry:)`); sementara itu
  worker melakukan polling.
- Push yang gagal melepas unique lock yang diambilnya dan mengembalikan
  pemilik debounce yang digantikannya, sehingga dispatch berikutnya dari
  unique job tidak dilewati dan dispatch debounced yang sudah ada di queue
  tetap berjalan.
- Di queue Redis, seperti di queue database, job yang payload-nya tidak bisa
  di-decode dihapus dan dicatat di `failed_jobs`.
- `serve` menolak `QUEUE_UNIQUE_LOCK_STORE=memory` dengan beberapa isolate
  atau dengan queue worker embedded: setiap isolate akan menyimpan lock-nya
  sendiri.
- `queue:work --memory=128` menghentikan worker dengan exit code 12 begitu
  prosesnya memakai sebanyak itu megabyte, seperti `--memory` di Laravel
  (tanpa batas secara default).

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
- `Queue.manager.route<SendEmail>(queue: 'emails')` menentukan tujuan satu tipe job,
  di satu tempat. `withoutDelay()` pada dispatch mengabaikan delay yang dideklarasikan
  job.
- `bool get deleteWhenMissingModels => true` membuang job yang modelnya sudah hilang.
  Model yang hilang kini langsung menggagalkan job, seperti di Laravel, bukan
  menghabiskan jatah percobaan.
- `Duration? get debounceFor` hanya menjalankan dispatch terakhir dari satu burst
  dengan `debounceId` yang sama, selama itu setelahnya. `debounceMaxWait` meloloskan
  burst yang panjang, dan job tidak bisa debounced sekaligus unique.

## Concurrency

`Concurrency.run` menjalankan beberapa task sekaligus di pool worker isolate yang
sudah hangat, lalu mengembalikan hasilnya sesuai urutan. Ini adalah facade
`Concurrency` Laravel, tanpa memulai satu proses untuk setiap task.

```dart
final [users, orders] = await Concurrency.run<int>([
  () => countLines(userFile),
  () => countLines(orderFile),
], timeout: const Duration(seconds: 30));
```

Semua task tetap berjalan. Setelah itu kegagalan pertama menurut posisi dilempar
ulang beserta stack trace-nya. Task yang melewati `timeout` gagal dengan
`TimeoutException`. `concurrency` membatasi satu `run`, dan
`Concurrency.maxWorkers` membatasi pool, secara default yang lebih kecil antara
jumlah prosesor dan 4. Dengan `serve --isolates=N`, setiap isolate punya pool
sendiri.

Task berjalan di isolate lain, dan di sinilah bedanya dengan Laravel, yang
mem-boot aplikasi untuk setiap task:

- Facade tidak berfungsi di sana. Kirim nilai yang dibutuhkan task, lalu kembalikan
  hasilnya.
- Closure mengirim semua yang ditangkapnya, dan closure di dalam fungsi async
  menangkap seluruh scope-nya. `Request` atau socket di scope itu gagal dengan
  `ArgumentError`, jadi buat task di fungsi kecil, atau pakai fungsi static.

`Concurrency.defer` menjalankan task di worker setelah response terkirim, dan
mencatat kegagalannya ke log. Untuk pekerjaan tertunda yang butuh facade, pakai
`Request.defer`.

`Concurrency.runIfLarge(payloadBytes, task)` menjalankan pekerjaan kecil di sini,
karena menyeberang ke worker lebih mahal daripada hasilnya, dan pekerjaan besar di
worker.

Di test, `Concurrency.sync(body)` menjalankan task satu per satu di isolate ini,
dan `Concurrency.fake((fake) async { … })` juga menghitungnya dengan
`assertRanCount` dan `assertDeferredCount`.

### Hasil biner

`Concurrency.runBytes` adalah `run` untuk task yang mengembalikan `Uint8List`:
PDF, CSV, gambar, atau body terkompresi. Hasil berukuran 32 KB atau lebih kembali
sebagai `TransferableTypedData`, disalin sekali di worker lalu dipindahkan ke
pemanggil tanpa salinan kedua. `Response.computed` mengirimnya sebagai body, juga
tanpa salinan:

```dart
final [pdf] = await Concurrency.runBytes([() => renderInvoice(data)]);
return Response.computed(pdf, contentType: 'application/pdf');
```

Kembalikan teks, termasuk JSON, dari `run` sebagai `String`: VM membagikan string
antar-isolate alih-alih menyalinnya, dan itu lebih cepat daripada transfer byte
apa pun. `IsolatePayload.text` dan `IsolatePayload.bytes` menerapkan aturan yang
sama untuk `SendPort` Anda sendiri: kirim `toWire()`, lalu panggil
`IsolatePayload.fromWire` sekali, di handler port penerima. Sebuah transferable
hanya bisa diterima sekali, jadi pesan yang dikirim ke banyak port tetap berupa
`String`.

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

Saat `SIGTERM`, `schedule:work` (dan scheduler embedded) tidak memulai task
baru dan menunggu task yang sedang berjalan, termasuk yang di background,
paling lama 30 detik (`Scheduler.stop(drain:)`; scheduler embedded memakai
tiga perempat dari shutdown timeout). Lock `withoutOverlapping` dari task
yang masih berjalan setelah itu dilepas dan task tersebut berakhir bersama
prosesnya, alih-alih menghalangi run berikutnya sampai lock-nya kedaluwarsa;
`dartisan schedule:clear-cache` melepas lock overlap yang tertinggal dari
scheduler yang di-kill. Task yang filter-nya (`when`, `skip`), lock-nya, atau
event listener-nya melempar exception dicatat ke log dan dilewati
(`ScheduledTaskSkipped` dengan alasan `error`), dan task lain di menit itu
tetap berjalan. Seperti di Laravel, lock `onOneServer` memakai ekspresi dan
nama task serta menit saat run dimulai, sehingga task lambat sebelumnya
tidak bisa menggesernya ke menit berikutnya di satu server; job tanpa nama
dari class yang sama dibedakan lewat datanya, dan closure tanpa nama
membutuhkan `named(...)`.

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

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `Cache::flexible($key, [$fresh, $stale], fn)` | `await Cache.flexible(...)` | `Cache.flexible` |  |
| `SendEmail::dispatch()->withoutDelay()` | `.withoutDelay()` | `PendingDispatch.withoutDelay` |  |
| `public $deleteWhenMissingModels = true` | `bool get deleteWhenMissingModels => true` | `Job.deleteWhenMissingModels` |  |
| `#[DebounceFor(60)]` | `Duration? get debounceFor => ...` | `Job.debounceFor` |  |
| `(new WithoutOverlapping($key))->shared()` | `WithoutOverlapping(key, shared: true)` | `WithoutOverlapping.shared` |  |
