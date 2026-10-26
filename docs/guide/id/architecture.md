<!-- source: architecture.md sha256:4452b41251b6 -->
# Arsitektur

Daravel mempertahankan konsep Laravel dan mengubah mekanisme yang tidak bisa
dibagi oleh bahasa bertipe statis yang dikompilasi ahead-of-time dengan PHP.

## Siklus hidup request

1. `bin/server` membangun aplikasi dari `createApp()` di
   `bootstrap/app.dart` dan mem-boot-nya: environment, konfigurasi bertipe
   beserta validasinya, binding container, service provider, route.
2. Setiap request berjalan di scope-nya sendiri (di bawah), melewati
   middleware global, router radix-tree, route model binding, middleware
   route, validasi yang dideklarasikan (`.validates()`), lalu handler.
3. Hasil handler menjadi respons: `Response`, resource, model, map atau list
   (JSON), string (teks), atau `null` (204).
4. Setelah respons ditulis, terminable middleware dan callback
   `request.defer()` dijalankan.

`404`, `405` (dengan `Allow`), `HEAD`, dan `OPTIONS` berperilaku seperti di
Laravel, dan exception dirender sebagai body error JSON dari Laravel.

## Service container

`Container` mengikat service sebagai singleton, scoped (satu per request,
job, atau command), atau factory transient. Service provider punya dua fase
seperti di Laravel:

```dart
final class BillingServiceProvider extends ServiceProvider {
  const BillingServiceProvider();

  @override
  void register(Container container) {
    container.singleton<PaymentGateway>((c) => StripeGateway(c.make<Env>()));
  }

  @override
  Future<void> boot(Container container) async {
    // Semua provider sudah register; resolve aman dilakukan di sini.
  }
}
```

`DeferredServiceProvider` mendaftarkan binding-nya saat salah satu tipenya
pertama kali di-resolve.

Untuk sedikit binding, `withBindings` menghemat kelas provider. Memanggil
container (`c()`) me-resolve tipe apa pun yang dibutuhkan argumennya,
sehingga factory tidak perlu menyebut tipe, dan `inject()` (`resolve()`
dari Laravel) melakukan hal yang sama di kode aplikasi:

```dart
Application.configure(basePath: '.')
    .withBindings((c) {
      c.singleton((c) => StripeGateway(c()));          // c() → Env
      c.singleton((c) => OrderService(c(), c()));      // → StripeGateway, Logger
      c.scoped((c) => RequestAudit(c()));              // → request ini
    });

final class OrderController {
  OrderController({OrderService? orders}) : orders = orders ?? inject();
  final OrderService orders;                           // sebuah fake di unit test
}
```

`withBindings` berjalan setelah binding milik framework, sehingga bisa
menggantinya, dan sebelum provider register, sehingga provider bisa memakai
service-nya. `maybeInject<T>()` mengembalikan `null` bila tidak ada yang
di-bind. Container ini bukan `get_it`: service scoped hidup di zone milik
request, sehingga request yang berjalan bersamaan tidak pernah melihat
instance milik yang lain.

## Zone sebagai pengganti state global

Request PHP dimulai dari proses yang kosong; server Dart menangani banyak
request sekaligus dalam satu proses. Daravel memberi setiap request, job di
queue, dan console command scope-nya sendiri yang disimpan di `Zone` Dart
(`Container.runScoped`). Facade seperti `Auth`, `DB`, `Cache`, dan `Log`
me-resolve dari zone saat ini lebih dulu, sehingga user yang sedang login,
request id di baris log, atau transaksi yang aktif tetap milik request yang
sedang berjalan, bahkan ketika request lain sedang tertahan di sebuah
`await`.

Transaksi memakai mekanisme yang sama: `DB.transaction` menaruh executor-nya
di zone, pemanggilan bersarang menjadi savepoint, dan job di queue atau
event `dispatchAfterCommit` menunggu commit terluar.

## Tanpa reflection, registry eksplisit

Biner AOT tidak punya `dart:mirrors`, dan compiler membuang kode yang tidak
di-import siapa pun. Apa yang ditemukan Laravel dengan memindai folder
menjadi list eksplisit di `bootstrap/`: `migrations.dart`, `seeders.dart`,
`jobs.dart`, `policies.dart`, `listeners.dart`, dan `commands.dart`.
`dartisan make:*` merawatnya, dan `dartisan lint` melaporkan file yang
tertinggal dari registry.

## Konkurensi

Dengan `APP_ISOLATES=N` (atau `serve --isolates=N`), supervisor menjalankan
N worker isolate yang berbagi satu port. Supervisor menunggu setiap worker
siap, menjalankan ulang worker yang crash (dan keluar bila crash terus
berulang), dan saat `SIGTERM` membiarkan request yang sedang berjalan
selesai dalam `SHUTDOWN_TIMEOUT`.

Isolate tidak berbagi memori, jadi state yang harus berlaku untuk seluruh
proses berada di isolate coordinator: rate limit (`throttle:60,1` berarti 60
per menit untuk seluruh server, bukan per worker), penyimpanan cache
`process`, atomic lock, dan metrik yang digabung. Setiap store
mendeklarasikan scope-nya (`isolate`, `process`, atau `cluster`); rate
limiting gagal terbuka, lock gagal tertutup.

## Waktu

Waktu domain (timestamp, kedaluwarsa token dan cache, jadwal, signed URL)
membaca `Clock.now()`, sehingga test bisa membekukan atau menggesernya
dengan `freezeTime()` dan `travel()`.
