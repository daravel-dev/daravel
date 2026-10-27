<!-- source: README.md sha256:dfcf5743092f -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_activitylog

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_activitylog/README.md) · Bahasa Indonesia

Riwayat perubahan model dan activity log untuk [Daravel](https://pub.dev/packages/daravel),
di tabel `activity_log` dari [spatie/laravel-activitylog](https://spatie.be/docs/laravel-activitylog)
v4: aplikasi Laravel yang memakai Spatie dan aplikasi Daravel berbagi tabel
ini, dan masing-masing membaca aktivitas yang ditulis pihak lain.

```bash
dart pub add daravel_activitylog
```

```dart
// bootstrap/app.dart
import 'package:daravel_activitylog/daravel_activitylog.dart';

Application createApp() => Application.configure(basePath: '.')
    .withActivityLog()
    .withMigrations([...migrations, const CreateActivityLogTable()])
    // ...
    .create();

final class Assessment extends Model with LogsActivity {
  static final ModelDefinition<Assessment> definition = ModelDefinition(
    table: 'assessments',
    factory: Assessment.new,
    observers: [ActivityLogObserver<Assessment>()],
  );
  // ...
  @override
  LogOptions get activitylogOptions =>
      LogOptions.defaults().logOnly(['score', 'status']).logOnlyDirty();
}
```

```dart
await exam.update({'score': 95}); // {attributes: {score: 95}, old: {score: 60}}
await activity('security').performedOn(exam).log('Exam locked');
await exam.activities().latest().get();
```

- `LogsActivity` mencatat `created`, `updated` beserta nilai lama,
  `deleted`, dan `restored` seperti Spatie, dengan `LogOptions` dari Spatie
  (`logOnly`, atribut relasi dan JSON, `logOnlyDirty`,
  `dontSubmitEmptyLogs`, ...).
- `activity()` dengan placeholder, user request sebagai causer,
  `LogBatch.within`, `ActivityLog.withoutLogs`, dan `Activity` dengan scope
  dari Spatie; `activitylog:clean`.
- Aktivitas ditulis di dalam transaksi model, dan log yang dimatikan atau
  sebuah batch hanya berlaku untuk satu callback, bukan seluruh proses.
- Diuji di SQLite, PostgreSQL, dan MariaDB, serta terhadap Laravel 12
  dengan Spatie 4.10.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/activitylog.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. spatie/laravel-activitylog adalah paket
berlisensi MIT dari Spatie; Daravel hanya berbagi tata letak database-nya.
Daravel adalah proyek independen, tidak berafiliasi dengan dan tidak
didukung oleh pihak mana pun di atas.
