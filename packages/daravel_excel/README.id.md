<!-- source: README.md sha256:8b2ba0432113 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_excel

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_excel/README.md) · Bahasa Indonesia

Ekspor dan impor Excel (XLSX) dan CSV untuk [Daravel](https://pub.dev/packages/daravel),
dengan concern dari [Laravel Excel](https://docs.laravel-excel.com) 3.1.
Sheet di-stream: ekspor 500.000 baris memakai puncak memori 24 MB yang
sama dengan ekspor 10.000 baris.

```bash
dart pub add daravel_excel
```

```dart
import 'package:daravel_excel/daravel_excel.dart';

final class StudentsExport implements FromQuery, WithHeadings, WithMapping {
  @override
  Object query() => Student.query().orderBy('name');

  @override
  List<Object?> headings() => ['NISN', 'Name', 'Score'];

  @override
  List<Object?> map(Object? row) {
    final s = row! as Student;
    return [s.nisn, s.name, s.score];
  }
}

router.get('/students.xlsx', (_) => Excel.download(StudentsExport(), 'students.xlsx'));
await Excel.store(StudentsExport(), 'reports/students.xlsx', disk: 's3');
await Excel.import(StudentsImport(), (await request.file('spreadsheet'))!);
```

- Ekspor dari query (per chunk), collection, atau stream, dengan heading,
  mapping, judul sheet, beberapa sheet, format angka, dan lebar kolom;
  hasilnya bisa berupa download, file di disk (termasuk S3), atau bytes.
- Impor ke model (satu per satu atau per batch), collection, atau baris,
  dengan heading row, validasi Daravel per baris (failure membawa nomor
  baris di sheet dan dirender sebagai 422), skip failure, chunk, baris
  awal, limit, dan pemilihan sheet, dalam satu transaksi.
- XLSX ditulis dan dibaca dengan pipeline ZIP dan XML streaming sendiri;
  CSV ditulis dan dibaca seperti PhpSpreadsheet. Tersedia `make:export`
  dan `make:import`.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/excel.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; "Excel" adalah merek dagang Microsoft
Corporation. Laravel Excel adalah paket berlisensi MIT dari Spartner;
Daravel hanya mengikuti API-nya. Daravel adalah proyek independen, tidak
berafiliasi dengan dan tidak didukung oleh pihak mana pun di atas.
