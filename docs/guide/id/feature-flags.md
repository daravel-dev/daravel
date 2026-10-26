<!-- source: feature-flags.md sha256:055d0a395e60 -->
# Feature flag

`Feature` adalah Laravel Pennant: sebuah fitur di-resolve sekali per scope
(secara default user yang sedang login), nilainya disimpan, dan pengecekan
berikutnya membacanya. Penyimpanannya adalah tabel `features` milik
Pennant, jadi aplikasi Laravel di database yang sama melihat flag yang sama;
dengan cara itulah sebuah fitur bisa berpindah dari satu framework ke yang
lain.

## Mendefinisikan dan mengecek

Definisikan fitur saat boot, misalnya di service provider atau
`bootstrap/app.dart`:

```dart
Feature.define('new-scoring-engine', (Object? scope) =>
    scope is User && scope.email.endsWith('@company.com'));

// Nilai kaya: nilai apa pun selain false berarti aktif.
Feature.define('checkout', (scope) => scope == null ? 'classic' : 'v2');
```

Cek di controller, job, dan command:

```dart
if (await Feature.active('new-scoring-engine')) { ... }
final variant = await Feature.value('checkout');          // 'classic' atau 'v2'
await Feature.forScope(team).active('new-scoring-engine'); // scope lain
await Feature.allAreActive(['a', 'b']);
```

`forScope` adalah `Feature::for` milik Pennant (`for` adalah kata kunci
Dart). Scope diserialisasi seperti di Pennant: `__laravel_null` bila tidak
ada, string dan angka apa adanya, model sebagai `App\Models\User|1`
(`morphClass` dan key-nya), atau implementasikan `FeatureScope` untuk yang
lain. Fitur yang tidak didefinisikan dianggap tidak aktif dan tidak ada yang
disimpan untuknya. Dalam satu request, job, atau command, setiap nilai
dibaca sekali.

## Mengubah nilai

```dart
await Feature.activate('checkout', 'v3');      // untuk user saat ini
await Feature.forScope(user).deactivate('new-scoring-engine');
await Feature.forget('checkout');               // resolve lagi lain kali
await Feature.activateForEveryone('new-scoring-engine');
await Feature.deactivateForEveryone('new-scoring-engine');
await Feature.purge(['checkout']);              // atau purge() untuk semua
```

Seperti di Pennant, `activateForEveryone` mengubah nilai yang tersimpan;
scope yang belum punya nilai tetap di-resolve melalui definisinya.

## Route

`feature:a,b` (`EnsureFeaturesAreActive` milik Pennant) menjawab
`400 Bad Request` kecuali setiap fitur yang dicantumkan aktif untuk user;
dengan `APP_DEBUG`, pesannya menyebut fitur-fitur itu.

```dart
router.get('/api/v2/scores', scores.index).middleware(const ['feature:new-scoring-engine']);
```

## Penyimpanan

`PENNANT_STORE` (variabel milik Laravel) memilih `database` (default;
tambahkan `CreateFeaturesTable()` ke `bootstrap/migrations.dart`, yang sudah
disertakan di proyek baru) atau `array` (memori, per isolate; default saat
`APP_ENV=testing`).
