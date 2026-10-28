import 'dart:async';

import 'package:daravel/daravel.dart';

import 'csv.dart';
import 'failure.dart';

// ---------------------------------------------------------------------------
// Exports (Laravel Excel's `Maatwebsite\Excel\Concerns`).
// ---------------------------------------------------------------------------

/// Rows from a query, read [WithCustomChunkSize.chunkSize] (1 000) at a
/// time: a `ModelQuery` (models, with their eager loads per chunk) or a
/// `QueryBuilder` (rows as maps).
abstract interface class FromQuery {
  Object query();
}

/// Rows from a list or any iterable held in memory.
abstract interface class FromCollection {
  FutureOr<Iterable<Object?>> collection();
}

/// Rows from a stream, consumed as the file is written (Laravel Excel's
/// `FromGenerator`).
abstract interface class FromGenerator {
  Stream<Object?> generator();
}

/// The first rows: a list of cells, or a list of lists for several
/// heading rows.
abstract interface class WithHeadings {
  List<Object?> headings();
}

/// Turns a source row into its cells; returning a list of lists writes
/// several rows.
abstract interface class WithMapping {
  FutureOr<List<Object?>> map(Object? row);
}

/// The sheet's name.
abstract interface class WithTitle {
  String title();
}

/// One sheet per export in [sheets].
abstract interface class WithMultipleSheets {
  List<Object> sheets();
}

/// Number format codes by column, `'D'` or `'B:D'` ([NumberFormat]).
abstract interface class WithColumnFormatting {
  Map<String, String> columnFormats();
}

/// Column widths by column letter.
abstract interface class WithColumnWidths {
  Map<String, double> columnWidths();
}

/// How many rows a [FromQuery] reads at a time.
abstract interface class WithCustomChunkSize {
  int get chunkSize;
}

/// CSV settings for an export or import.
abstract interface class WithCustomCsvSettings {
  CsvSettings getCsvSettings();
}

// ---------------------------------------------------------------------------
// Imports.
// ---------------------------------------------------------------------------

/// Each row becomes a model; an unsaved one is saved (in a batch with
/// [WithBatchInserts]). Return `null` to skip the row.
abstract interface class ToModel {
  FutureOr<Model?> model(Map<String, Object?> row);
}

/// All rows at once (or [WithChunkReading.chunkSize] at a time).
abstract interface class ToCollection {
  FutureOr<void> collection(List<Map<String, Object?>> rows);
}

/// Each row with its sheet row number.
abstract interface class OnEachRow {
  FutureOr<void> onRow(ExcelRow row);
}

/// The row whose cells name the columns: rows become maps keyed by those
/// names, slugged with `_` (`Nama Lengkap` → `nama_lengkap`).
abstract mixin class WithHeadingRow {
  /// The heading row's number (1 by default).
  int headingRow() => 1;
}

/// The first row to import.
abstract interface class WithStartRow {
  int startRow();
}

/// The most rows to import.
abstract interface class WithLimit {
  int limit();
}

/// Validates every row with Daravel's rules; failing rows are reported
/// with their row numbers ([ExcelValidationException]), or skipped with
/// [SkipsOnFailure].
abstract interface class WithValidation {
  Map<String, Object> rules();
}

/// Validation messages by `attribute.rule`, for [WithValidation].
abstract interface class WithCustomValidationMessages {
  Map<String, String> customValidationMessages();
}

/// Display names of attributes in validation messages.
abstract interface class WithCustomValidationAttributes {
  Map<String, String> customValidationAttributes();
}

/// Reads and handles rows [chunkSize] at a time.
abstract interface class WithChunkReading {
  int get chunkSize;
}

/// Inserts models in batches of [batchSize] with one query each (no model
/// events), as Laravel Excel does.
abstract interface class WithBatchInserts {
  int get batchSize;
}

/// Skips rows whose cells are all empty.
abstract mixin class SkipsEmptyRows {}

/// Receives the failures of skipped rows instead of the import stopping.
abstract interface class SkipsOnFailure {
  void onFailure(List<Failure> failures);
}

/// [SkipsOnFailure] that keeps the failures for [failures].
mixin SkipsFailures implements SkipsOnFailure {
  final List<Failure> _failures = [];

  @override
  void onFailure(List<Failure> failures) => _failures.addAll(failures);

  List<Failure> failures() => List.unmodifiable(_failures);
}

/// The sheet to import, by zero-based index or name, for a single-sheet
/// import (the first sheet otherwise).
abstract interface class WithSheetSelection {
  Object get sheet;
}

/// Imports per sheet: imports keyed by zero-based index or sheet name.
abstract interface class WithMultipleSheetImports {
  Map<Object, Object> sheets();
}

/// An imported row (Laravel Excel's `Row`).
final class ExcelRow {
  const ExcelRow(this.index, this.values);

  /// The row's number in the sheet (1-based).
  final int index;

  /// Its cells, keyed by heading ([WithHeadingRow]) or by column index.
  final Map<String, Object?> values;

  Object? operator [](String key) => values[key];
}
