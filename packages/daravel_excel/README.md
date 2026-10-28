<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_excel

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_excel/README.id.md)

Excel (XLSX) and CSV exports and imports for [Daravel](https://pub.dev/packages/daravel),
with the concerns of [Laravel Excel](https://docs.laravel-excel.com) 3.1.
Sheets are streamed: an export of 500 000 rows peaks at the same 24 MB as
one of 10 000.

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

- Exports from a query (a chunk at a time), a collection or a stream, with
  headings, mapping, sheet titles, several sheets, number formats and
  column widths; downloads, disks (S3 too), bytes.
- Imports to models (one by one or in batches), collections or rows, with
  heading rows, Daravel's validation per row (failures carry the sheet row
  number and render as a 422), skipped failures, chunks, start rows,
  limits and sheet selection, in one transaction.
- XLSX written and read with a streaming ZIP and XML pipeline of its own;
  CSV as PhpSpreadsheet writes and reads it. `make:export` and
  `make:import`.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/excel.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; "Excel" is a trademark of Microsoft Corporation.
Laravel Excel is Spartner's MIT-licensed package; Daravel only follows its
API. Daravel is an independent project, not affiliated with or endorsed by
any of them.
