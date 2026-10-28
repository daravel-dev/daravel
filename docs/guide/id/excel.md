<!-- source: excel.md sha256:d77a05f151c5 -->
# Excel dan CSV

`daravel_excel` mengekspor dan mengimpor spreadsheet dengan concern dari
[Laravel Excel](https://docs.laravel-excel.com) 3.1 (`FromQuery`,
`WithHeadings`, `ToModel`, `WithValidation`, ...). Sheet ditulis sambil
dibaca: baris diambil dari database per chunk lalu langsung dikirim sebagai
XLSX terkompresi (atau CSV) ke client HTTP atau ke disk, sehingga ekspor
500.000 baris memakai memori yang sama dengan ekspor 10 baris.

```bash
dart pub add daravel_excel
```

Tidak perlu setup: `Excel` memakai database, storage, dan validasi
aplikasi.

## Ekspor

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
      student.createdAt, // DateTime menjadi tanggal Excel
    ];
  }

  @override
  Map<String, String> columnFormats() => {'D': NumberFormat.number00};
}
```

```dart
// Download yang di-stream (tipe file mengikuti ekstensi)
router.get('/reports/students.xlsx', (Request request) =>
    Excel.download(StudentsExport(1), 'students-2026.xlsx'));

// File di disk, lokal atau S3 (daravel_s3), juga di-stream
await Excel.store(StudentsExport(1), 'reports/students.xlsx', disk: 's3');

// Bytes atau stream
final bytes = await Excel.raw(StudentsExport(1), ExcelType.csv);
```

| Concern | |
| :-- | :-- |
| `FromQuery` | `ModelQuery` (model, beserta eager load per chunk) atau `QueryBuilder` (map), dibaca 1.000 baris sekali jalan (`WithCustomChunkSize`) |
| `FromCollection` | list atau iterable apa pun |
| `FromGenerator` | sebuah `Stream`, dibaca sambil file ditulis |
| `WithHeadings` | baris pertama (list of list untuk beberapa baris heading) |
| `WithMapping` | mengubah baris sumber menjadi sel (list of list untuk beberapa baris) |
| `WithTitle` | nama sheet (dibuat valid: maksimal 31 karakter, tanpa `[]:*?/\`) |
| `WithMultipleSheets` | satu sheet per export di `sheets()` |
| `WithColumnFormatting` | format angka per kolom, `'D'` atau `'B:D'` (`NumberFormat`) |
| `WithColumnWidths` | lebar per kolom |
| `WithCustomCsvSettings` | delimiter, enclosure, akhir baris, byte order mark |

Tanpa `WithMapping`, model ditulis sebagai nilai JSON-nya, map sebagai
nilainya, dan list apa adanya. Di XLSX, angka, boolean, dan tanggal tetap
bertipe (`DateTime` tepat tengah malam diformat sebagai tanggal, selain itu
sebagai tanggal dan jam); teks ditulis inline, sehingga tidak ada tabel
shared strings yang membesar di memori. CSV membungkus setiap field dengan
tanda kutip, seperti writer PhpSpreadsheet, dan hanya berisi sheet
pertama.

Berbeda dengan Laravel Excel, tidak ada `ShouldAutoSize`: nilai terlebar
sebuah kolom baru diketahui setelah semua baris ditulis, padahal file
di-stream. Gunakan `WithColumnWidths`.

## Impor

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

`WithHeadingRow` memberi key pada setiap baris dari sel baris pertama,
di-slug dengan `_` (`Full Name` → `full_name`); heading kosong memakai
indeks kolomnya sebagai key. Tanpa concern ini, key baris adalah `'0'`,
`'1'`, .... Sumbernya bisa `UploadedFile`, path di disk
(`Excel.import(import, 'in/file.xlsx', disk: 's3')`), atau bytes.

Impor berjalan dalam satu transaksi database. Bila sebuah baris gagal
validasi, impor melempar `ExcelValidationException`, yaitu
`ValidationException` yang error-nya ber-key `<baris>.<atribut>` dengan
nomor baris di sheet, sehingga exception handler menjawab 422 bergaya
Laravel dan tidak ada data yang tersimpan:

```json
{
  "message": "The email field must be a valid email address. (and 1 more error)",
  "errors": {
    "3.email": ["The email field must be a valid email address."],
    "3.average": ["The average field must be between 0 and 100."]
  }
}
```

`e.failures` berisi daftar `Failure(row, attribute, errors, values)`,
seperti `failures()` di Laravel Excel. Dengan `SkipsOnFailure` (atau mixin
`SkipsFailures`, yang menyimpannya di `failures()`), baris yang gagal
dilewati dan baris lainnya tetap disimpan.

| Concern | |
| :-- | :-- |
| `ToModel` | baris menjadi model; model yang belum tersimpan akan disimpan, `null` melewati baris |
| `ToCollection` | semua baris sekaligus, atau per chunk dengan `WithChunkReading` |
| `OnEachRow` | setiap baris beserta nomor barisnya di sheet (`ExcelRow.index`) |
| `WithHeadingRow` | baris ber-key heading (`headingRow()` default 1) |
| `WithStartRow` / `WithLimit` | baris awal, jumlah baris |
| `WithValidation` | rule Daravel per baris (`'*.email'` juga diterima) |
| `WithCustomValidationMessages` / `WithCustomValidationAttributes` | pesan dan nama atribut |
| `WithChunkReading` | baris diproses per `chunkSize` |
| `WithBatchInserts` | satu `INSERT` per `batchSize` model (tanpa event model) |
| `SkipsEmptyRows` | lewati baris yang semua selnya kosong |
| `SkipsOnFailure` / `SkipsFailures` | lewati baris gagal alih-alih berhenti |
| `WithSheetSelection` / `WithMultipleSheetImports` | pilih sheet berdasarkan indeks atau nama, atau satu import per sheet |

Sel terbaca sebagai `int`, `double`, `bool`, atau `String`. Sel tanggal
berupa nomor seri Excel, seperti yang dikembalikan Laravel Excel: ubah
dengan `ExcelDate.toDateTime(row['date']! as num)`. Sel formula memberi
nilai yang dihitung Excel saat file disimpan. Di CSV, `true` dan `false`
(huruf besar atau kecil) menjadi boolean dan teks berbentuk angka menjadi
angka kecuali diawali nol (`0123` tetap teks), seperti cara PhpSpreadsheet
membacanya, dan delimiter dideteksi di antara `,`, `;`, tab, dan `|`.

`Excel.toArray(source, headingRow: true)` mengembalikan baris dari semua
sheet.

## Command

```dart
// bootstrap/commands.dart
import 'package:daravel_excel/commands.dart';

final List<CommandFactory> commands = [...excelCommands];
```

```bash
dartisan make:export StudentsExport --model=Student   # lib/app/exports/
dartisan make:import StudentsImport --model=Student   # lib/app/imports/
```

## Queue

Export adalah class di aplikasi Anda, jadi ekspor lewat queue adalah job
Anda sendiri yang memanggil `Excel.store` (didaftarkan di
`bootstrap/jobs.dart` seperti job lainnya):

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

## Memori

`bench/bin/excel_memory.dart` menulis sepuluh kolom bertipe campuran (build
AOT, Windows 11, Dart 3.13.4):

| Baris | Tipe | File | Waktu | Puncak memori |
| --: | :-- | --: | --: | --: |
| 10.000 | XLSX | 0,5 MB | 0,2 s | 24 MB |
| 100.000 | XLSX | 5,0 MB | 1,9 s | 24 MB |
| 500.000 | XLSX | 25,1 MB | 9,9 s | 24 MB |
| 500.000 | CSV | 82,4 MB | 2,4 s | 24 MB |

Angka memori adalah puncak seluruh proses, termasuk runtime; nilainya
tidak bertambah seiring jumlah baris. Pembacaan juga men-stream sheet
dengan cara yang sama; shared strings sebuah XLSX (teks yang disimpan Excel
sekali per workbook) disimpan di memori selama workbook dibaca.

## File Laravel Excel

`bench/interop/excel.sh` menjalankan Laravel 12 dengan maatwebsite/excel
3.1 dan Daravel: masing-masing membaca file XLSX dan CSV yang ditulis pihak
lain, lengkap dengan teks, angka, boolean, sel kosong, dan tanggal.
