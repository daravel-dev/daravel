/// Excel and CSV for Daravel (Blueprint #39): exports and imports with
/// Laravel Excel's concerns, streamed so a sheet of any length uses the
/// same memory.
///
/// ```dart
/// final class StudentsExport implements FromQuery, WithHeadings, WithMapping { ... }
///
/// router.get('/students.xlsx', (_) => Excel.download(StudentsExport(), 'students.xlsx'));
/// await Excel.import(StudentsImport(), request.file('spreadsheet')!);
/// ```
library;

export 'src/cells.dart' show ExcelDate, NumberFormat, columnIndex, columnLetter;
export 'src/concerns.dart';
export 'src/csv.dart' show CsvSettings;
export 'src/excel.dart';
export 'src/exporter.dart' show ExcelType;
export 'src/failure.dart';
export 'src/xlsx_reader.dart' show SheetInfo, SheetRow, XlsxReader;
export 'src/xlsx_writer.dart' show XlsxWriter;
export 'src/zip.dart' show RandomAccessSource, ZipFormatException;
