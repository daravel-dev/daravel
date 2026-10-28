# Excel and CSV

`daravel_excel` exports and imports spreadsheets with the concerns of
[Laravel Excel](https://docs.laravel-excel.com) 3.1 (`FromQuery`,
`WithHeadings`, `ToModel`, `WithValidation`, ...). A sheet is written as it
is read: rows come from the database a chunk at a time and leave as
deflated XLSX (or CSV) straight to the HTTP client or a disk, so an export
of 500 000 rows uses the memory of an export of 10.

```bash
dartisan pub:add excel
```

`pub:add` adds the dependency and the [commands](#commands); with
`dart pub add daravel_excel` you add the commands yourself. No other setup
is needed: `Excel` uses the application's database, storage and
validation.

## Exports

```dart
import 'package:daravel_excel/daravel_excel.dart';

final class StudentsExport
    implements FromQuery, WithHeadings, WithMapping, WithColumnFormatting {
  StudentsExport(this.schoolId);
  final int schoolId;

  @override
  Object query() => Student.query()
      .where('school_id', schoolId)
      .with_(['classroom'])
      .orderBy('name');

  @override
  List<Object?> headings() => ['NISN', 'Name', 'Class', 'Average', 'Registered'];

  @override
  List<Object?> map(Object? row) {
    final student = row! as Student;
    return [
      student.nisn,
      student.name.toUpperCase(),
      student.classroom?.name ?? '-',
      student.averageScore,
      student.createdAt, // a DateTime becomes an Excel date
    ];
  }

  @override
  Map<String, String> columnFormats() => {'D': NumberFormat.number00};
}
```

```dart
// A streamed download (the type follows the extension)
router.get('/reports/students.xlsx', (Request request) =>
    Excel.download(StudentsExport(1), 'students-2026.xlsx'));

// A file on a disk, local or S3 (daravel_s3), streamed too
await Excel.store(StudentsExport(1), 'reports/students.xlsx', disk: 's3');

// Bytes or a stream
final bytes = await Excel.raw(StudentsExport(1), ExcelType.csv);
```

| Concern | |
| :-- | :-- |
| `FromQuery` | a `ModelQuery` (models, with their eager loads per chunk) or a `QueryBuilder` (maps), read 1 000 rows at a time (`WithCustomChunkSize`) |
| `FromCollection` | a list or any iterable |
| `FromGenerator` | a `Stream`, consumed as the file is written |
| `WithHeadings` | the first row (a list of lists for several) |
| `WithMapping` | a source row to its cells (a list of lists for several rows) |
| `WithTitle` | the sheet's name (made valid: 31 characters, no `[]:*?/\`) |
| `WithMultipleSheets` | one sheet per export in `sheets()` |
| `WithColumnFormatting` | number formats by column, `'D'` or `'B:D'` (`NumberFormat`) |
| `WithColumnWidths` | widths by column |
| `WithCustomCsvSettings` | delimiter, enclosure, line ending, byte order mark |

Without `WithMapping`, a model is written as its JSON values, a map as its
values, a list as it is. Numbers, booleans and dates keep their type in
XLSX (a `DateTime` at midnight is formatted as a date, otherwise as date
and time); text is written inline, so no shared-strings table grows in
memory. A CSV encloses every field, as PhpSpreadsheet's writer does, and
holds the first sheet.

Unlike Laravel Excel there is no `ShouldAutoSize`: a column's widest
value is only known once every row is written, and the file is streamed.
Use `WithColumnWidths`.

## Imports

```dart
final class StudentsImport
    with WithHeadingRow, SkipsEmptyRows
    implements ToModel, WithValidation, WithBatchInserts {
  StudentsImport(this.schoolId);
  final int schoolId;

  @override
  Model? model(Map<String, Object?> row) => Student.definition.newInstance({
    'school_id': schoolId,
    'nisn': '${row['nisn']}',
    'name': row['full_name'],
    'average_score': row['average'],
  });

  @override
  Map<String, Object> rules() => {
    'nisn': 'required|unique:students,nisn',
    'full_name': 'required|string|max:150',
    'average': 'nullable|numeric|between:0,100',
  };

  @override
  int get batchSize => 500;
}
```

```dart
router.post('/students/import', (Request request) async {
  await Excel.import(StudentsImport(1), (await request.file('spreadsheet'))!);
  return {'message': 'Imported.'};
});
```

`WithHeadingRow` keys each row by the first row's cells, slugged with `_`
(`Full Name` → `full_name`); an empty heading is keyed by its column index.
Without it rows are keyed `'0'`, `'1'`, .... The source is an
`UploadedFile`, a path on a disk (`Excel.import(import, 'in/file.xlsx',
disk: 's3')`) or bytes.

The import runs in one database transaction. When a row fails validation
it throws `ExcelValidationException`, a `ValidationException` whose errors
are keyed `<row>.<attribute>` with the row's number in the sheet, so the
exception handler answers a Laravel-style 422 and nothing is saved:

```json
{
  "message": "The email field must be a valid email address. (and 1 more error)",
  "errors": {
    "3.email": ["The email field must be a valid email address."],
    "3.average": ["The average field must be between 0 and 100."]
  }
}
```

`e.failures` lists `Failure(row, attribute, errors, values)`, as Laravel
Excel's `failures()`. With `SkipsOnFailure` (or the `SkipsFailures` mixin,
which keeps them in `failures()`) failing rows are skipped and the others
saved.

| Concern | |
| :-- | :-- |
| `ToModel` | a row to a model; an unsaved one is saved, `null` skips the row |
| `ToCollection` | all rows at once, or a chunk at a time with `WithChunkReading` |
| `OnEachRow` | each row with its sheet row number (`ExcelRow.index`) |
| `WithHeadingRow` | rows keyed by headings (`headingRow()` is 1 by default) |
| `WithStartRow` / `WithLimit` | where to start, how many rows |
| `WithValidation` | Daravel's rules per row (`'*.email'` is accepted too) |
| `WithCustomValidationMessages` / `WithCustomValidationAttributes` | messages and attribute names |
| `WithChunkReading` | rows handled `chunkSize` at a time |
| `WithBatchInserts` | one `INSERT` per `batchSize` models (no model events) |
| `SkipsEmptyRows` | rows whose cells are all empty |
| `SkipsOnFailure` / `SkipsFailures` | skip failing rows instead of stopping |
| `WithSheetSelection` / `WithMultipleSheetImports` | a sheet by index or name, or an import per sheet |

Cells come as `int`, `double`, `bool` or `String`. A date cell is its
Excel serial number, as Laravel Excel returns it: convert it with
`ExcelDate.toDateTime(row['date']! as num)`. A formula cell gives the
value Excel computed when the file was saved. In a CSV, `true` and
`false` (in any case) become booleans and numeric text becomes a number
unless it has a leading zero (`0123` stays text), as PhpSpreadsheet reads
it, and the delimiter is detected among `,`, `;`, tab and `|`.

`Excel.toArray(source, headingRow: true)` returns every sheet's rows.

## Commands

```dart
// bootstrap/commands.dart
import 'package:daravel_excel/commands.dart';

final List<CommandFactory> commands = [...excelCommands];
```

```bash
dartisan make:export StudentsExport --model=Student   # lib/app/exports/
dartisan make:import StudentsImport --model=Student   # lib/app/imports/
```

## Queues

Exports are classes of your application, so a queued export is a job of
yours that calls `Excel.store` (registered in `bootstrap/jobs.dart` like
any job):

```dart
final class ExportStudents extends Job {
  const ExportStudents(this.schoolId);
  final int schoolId;

  factory ExportStudents.fromJson(Map<String, Object?> json) =>
      ExportStudents(json['school_id']! as int);

  @override
  String get jobName => 'export-students';

  @override
  Map<String, Object?> toJson() => {'school_id': schoolId};

  @override
  Duration get timeout => const Duration(minutes: 30);

  @override
  Future<void> handle(JobContext ctx) =>
      Excel.store(StudentsExport(schoolId), 'reports/$schoolId.xlsx', disk: 's3');
}
```

## Memory

`bench/bin/excel_memory.dart` writes ten columns of mixed types (an AOT
build, Windows 11, Dart 3.13.4):

| Rows | Type | File | Time | Peak memory |
| --: | :-- | --: | --: | --: |
| 10 000 | XLSX | 0.5 MB | 0.2 s | 24 MB |
| 100 000 | XLSX | 5.0 MB | 1.9 s | 24 MB |
| 500 000 | XLSX | 25.1 MB | 9.9 s | 24 MB |
| 500 000 | CSV | 82.4 MB | 2.4 s | 24 MB |

The memory is the process's whole peak, the runtime included; it does not
grow with the rows. Reading streams a sheet the same way; the shared
strings of an XLSX (text that Excel stores once per workbook) are held in
memory while the workbook is read.

## Laravel Excel files

`bench/interop/excel.sh` runs Laravel 12 with maatwebsite/excel 3.1 and
Daravel: each reads the XLSX and CSV files the other writes, with text,
numbers, booleans, empty cells and dates.
