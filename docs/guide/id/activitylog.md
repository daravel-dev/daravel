<!-- source: activitylog.md sha256:7a0e2891082d -->
# Activity log

`daravel_activitylog` mencatat siapa mengubah apa pada model Anda, juga
aktivitas lain yang Anda catat sendiri, di tabel `activity_log` dari
[spatie/laravel-activitylog](https://spatie.be/docs/laravel-activitylog)
v4. Aplikasi Laravel yang memakai Spatie dan aplikasi Daravel bisa berbagi
tabel ini: masing-masing membaca aktivitas yang ditulis pihak lain, lengkap
dengan subject, causer, dan batch-nya.

```bash
dart pub add daravel_activitylog
```

```dart
// bootstrap/app.dart
import 'package:daravel_activitylog/daravel_activitylog.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withActivityLog()
    .withMigrations([...migrations, const CreateActivityLogTable()])
    .withModels(models)
    // ...
    .create();
```

`CreateActivityLogTable` membuat tabel hasil tiga migration v4 dari Spatie
(`create_activity_log_table`, `add_event_column`, `add_batch_uuid_column`)
dengan urutan kolom dan nama index yang sama, dan tidak melakukan apa pun
bila tabelnya sudah ada, sehingga database yang sudah menjalankan migration
Spatie tetap memakainya. Spatie v5 mengubah tabel ini (`attribute_changes`,
tanpa `batch_uuid`); paket ini mengikuti v4 (4.x), yang didukung Laravel
12 bersama v5.

## Mencatat perubahan model

Model memakai mixin `LogsActivity`, menentukan apa yang dicatat, dan
mendaftarkan `ActivityLogObserver` di observer-nya (Daravel tidak punya boot
hook yang bisa memasangnya otomatis):

```dart
final class Assessment extends Model with LogsActivity {
  static final ModelDefinition<Assessment> definition =
      ModelDefinition<Assessment>(
        table: 'assessments',
        factory: Assessment.new,
        fillable: ['title', 'score', 'status'],
        observers: [ActivityLogObserver<Assessment>()],
      );

  @override
  ModelDefinition<Assessment> get modelDefinition => Assessment.definition;

  static ModelQuery<Assessment> query() => definition.query();

  @override
  LogOptions get activitylogOptions => LogOptions.defaults()
      .logOnly(['title', 'score', 'status'])
      .logOnlyDirty()
      .dontSubmitEmptyLogs()
      .useLogName('assessments');
}
```

Menyimpan perubahan menulis satu baris, sama seperti Spatie menulisnya:

```dart
final exam = (await Assessment.query().find(42))!;
await exam.update({'score': 95, 'status': 'graded'});
```

```json
{
  "log_name": "assessments",
  "description": "updated",
  "event": "updated",
  "subject_type": "App\\Models\\Assessment",
  "subject_id": 42,
  "causer_type": "App\\Models\\User",
  "causer_id": 7,
  "properties": {
    "attributes": {"score": 95, "status": "graded"},
    "old": {"score": 60, "status": "in_progress"}
  }
}
```

`created` menyimpan `attributes`, `updated` menambahkan `old`, `deleted`
hanya menyimpan `old`, dan model dengan soft delete juga mencatat
`restored`. Nilainya dibaca ulang dari database setelah perubahan
(`fresh()` seperti Spatie), sehingga nilai default yang diisi database ikut
tercatat; tanggal ditulis dengan format serialisasi Laravel
(`2026-10-28T07:30:00.000000Z`), enum sesuai nilai yang disimpan.

| `LogOptions` | Yang dicatat |
| :-- | :-- |
| `logOnly([...])` | atribut ini; termasuk `author.name` (kolom relasi) dan `meta->room.name` (di dalam JSON) |
| `logAll()` | semua atribut, termasuk yang hidden: pasangkan dengan `logExcept` |
| `logFillable()` / `logUnguarded()` | `fillable` model, atau atribut yang tidak ada di `guarded` |
| `logExcept([...])` | kecuali atribut ini |
| `logOnlyDirty()` | saat update, hanya atribut tercatat yang berubah |
| `dontSubmitEmptyLogs()` | tidak mencatat apa pun bila tidak ada atribut tercatat yang berubah |
| `dontLogIfAttributesChangedOnly([...])` | tidak mencatat bila hanya atribut ini yang berubah (`updated_at`, sebuah counter) |
| `useLogName('...')` | `log_name` (selain itu log default) |
| `setDescriptionForEvent((event) => ...)` | deskripsinya; deskripsi kosong tidak mencatat apa pun |
| `useAttributeRawValues([...])` | atribut ini apa adanya, tanpa cast atau accessor |

`ActivityLogObserver(recordEvents: [...], doNotRecordEvents: [...])`
mengganti atau mengurangi daftar event (`$recordEvents` dan
`$doNotRecordEvents` di Spatie). `model.disableLogging()` menghentikan
pencatatan untuk satu instance, dan override `tapActivity(activity,
eventName)` mengubah aktivitas sebelum disimpan.

Seperti di Laravel, model yang baru saja Anda buat tidak memegang nilai
default yang diberikan database, sehingga setiap update membandingkan kolom
tersebut dengan `null` sampai model dimuat ulang (`await model.refresh()`).
Isi nilainya saat membuat model agar catatan seperti itu tidak muncul.

Aktivitas ditulis di dalam transaksi model: rollback menghapusnya bersama
perubahan yang dicatatnya, sehingga log tidak pernah memuat perubahan yang
tidak terjadi.

## Mencatat secara manual

```dart
await activity('security')
    .performedOn(examSession)
    .causedBy(user)
    .withProperties({'ip': request.ip, 'tab_switches': 3})
    .event('locked')
    .log(':causer.name locked :subject.title from :properties.ip');
```

`:subject.*`, `:causer.*`, dan `:properties.*` di deskripsi diganti dengan
nilainya, seperti di Spatie. `causedByAnonymous()`, `withProperty()`,
`createdAt()`, dan `tap((activity) => ...)` bekerja seperti di Spatie.

## Causer

Causer adalah user terautentikasi pada request (dari guard yang disebut
`ACTIVITY_LOGGER_AUTH_GUARD`, atau guard request bila tidak diisi), bila
user itu sebuah model. Di dalam command atau job tidak ada causer, kecuali
Anda memilihnya:

```dart
await ActivityLog.causedBy(admin, () async {
  await importStudents(file); // semua aktivitas di dalamnya dicatat atas nama admin
});
```

`causedBy` menggantikan `CauserResolver::setCauser()` dari Spatie, dan
`ActivityLog.withoutLogs(() async { ... })` menggantikan `withoutLogs()`.
Keduanya hanya berlaku selama callback berjalan: apa yang di Spatie
disimpan di singleton, di sini dibatasi pada sebuah zone, sehingga satu
request tidak pernah mematikan pencatatan untuk request lain yang berjalan
bersamaan.

## Batch

```dart
await LogBatch.within((uuid) async {
  await session.update({'status': 'finished'});
  await score.update({'total': 90});
});
```

Semua aktivitas di dalamnya memakai satu `batch_uuid`, dan batch yang dibuka
di dalam batch lain tetap memakai UUID luar. `LogBatch.using(uuid, ...)`
melanjutkan batch di tempat lain, misalnya di job yang di-dispatch oleh
request.

## Membaca log

```dart
final history = await exam.activities().latest().take(10).get();
for (final entry in history) {
  final who = await entry.causer();
  print('${who?['name']} ${entry.description} at ${entry.createdAt}');
  print(entry.changes); // {attributes: {...}, old: {...}}
}

await user.actions().get();                 // dengan CausesActivity pada User
await Activity.query().inLog('security').get();
await Activity.query().causedBy(user).forEvent('updated').get();
await Activity.query().forBatch(uuid).get();
await Activity.query().with_('causer').get(); // eager loading
```

`subject()` dan `causer()` memuat model yang disebut kolom `*_type`. Tanpa
reflection, Daravel mencarinya di antara model `withModels(...)` atau di
morph map (`Relation.morphMap`); baris yang ditulis Laravel menyimpan nama
class seperti `App\Models\User`, yang cocok dengan `morphClass` model.
`getExtraProperty('a.b')` membaca property bertingkat.

## Membersihkan log

```bash
dartisan activitylog:clean              # lebih lama dari 365 hari
dartisan activitylog:clean security --days=30
```

```dart
// bootstrap/commands.dart
import 'package:daravel_activitylog/commands.dart';

final List<CommandFactory> commands = [...activitylogCommands];

// scheduler
schedule.command('activitylog:clean').daily();
```

Di production, command ini butuh `--force`, karena versi Spatie meminta
konfirmasi.

## Konfigurasi

| Variabel | Default | |
| :-- | :-- | :-- |
| `ACTIVITY_LOGGER_ENABLED` | `true` | `false` tidak menulis apa pun |
| `ACTIVITY_LOGGER_TABLE_NAME` | `activity_log` | |
| `ACTIVITY_LOGGER_DB_CONNECTION` | koneksi default | |
| `ACTIVITY_LOGGER_DEFAULT_LOG_NAME` | `default` | |
| `ACTIVITY_LOGGER_DELETE_RECORDS_OLDER_THAN_DAYS` | `365` | untuk `activitylog:clean` |
| `ACTIVITY_LOGGER_AUTH_GUARD` | guard request | `default_auth_driver` di Spatie |
| `ACTIVITY_LOGGER_SUBJECT_RETURNS_SOFT_DELETED_MODELS` | `false` | |

Tiga variabel pertama adalah variabel Spatie; sisanya adalah pengaturan
yang di Spatie disimpan di `config/activitylog.php`.

## Berbagi tabel dengan Laravel

`bench/interop/activitylog.sh` menjalankan Laravel 12 dengan
spatie/laravel-activitylog 4.10 dan Daravel di satu database. Daravel
membaca aktivitas created dan updated dari Laravel, serta aktivitas manual
lengkap dengan subject, causer, dan batch-nya; Laravel membaca aktivitas
dari Daravel, dan model yang dibuat Daravel mencatat key dan format tanggal
yang sama dengan model yang dibuat Laravel.

Belum di-port: change pipe Spatie (`addLogChange`), saklar global
`disableLogging()`/`enableLogging()` (gunakan `withoutLogs`), dan causer
yang diberikan sebagai id, bukan model.
