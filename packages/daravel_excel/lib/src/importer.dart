import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';

import 'concerns.dart';
import 'csv.dart';
import 'exporter.dart';
import 'failure.dart';
import 'xlsx_reader.dart';
import 'zip.dart';

/// Where an import reads from: a file on disk or bytes in memory.
final class ImportSource {
  ImportSource.path(this.path) : bytes = null;
  ImportSource.bytes(List<int> this.bytes) : path = null;

  final String? path;
  final List<int>? bytes;

  Future<RandomAccessSource> open() async => path != null
      ? await RandomAccessSource.file(path!)
      : RandomAccessSource.bytes(bytes!);

  Stream<List<int>> read() =>
      path != null ? File(path!).openRead() : Stream.value(bytes!);
}

/// Runs [import] over [source] of [type], in one database transaction
/// unless [transaction] is false.
Future<void> runImport(
  Object import,
  ImportSource source,
  ExcelType type, {
  bool transaction = true,
}) async {
  Future<void> body() async {
    if (type == ExcelType.xlsx) {
      final reader = await XlsxReader.open(await source.open());
      try {
        for (final (sheetImport, sheet) in _selectSheets(
          import,
          reader.sheets,
        )) {
          await _importRows(
            sheetImport,
            reader.rows(sheet).map((row) => (row.number, row.cells)),
          );
        }
      } finally {
        await reader.close();
      }
      return;
    }
    final target = import is WithMultipleSheetImports
        ? (import.sheets()[0] ?? import.sheets().values.first)
        : import;
    final settings = target is WithCustomCsvSettings
        ? target.getCsvSettings()
        : (type == ExcelType.tsv ? CsvSettings.tsv : const CsvSettings());
    var number = 0;
    await _importRows(
      target,
      parseCsv(
        source.read(),
        settings,
      ).map((cells) => (++number, [for (final cell in cells) _csvValue(cell)])),
    );
  }

  if (transaction) {
    await DB.transaction(body);
  } else {
    await body();
  }
}

/// Every sheet's rows (`Excel.toArray`): keyed by the first row's
/// headings when [headingRow], by column index otherwise.
Future<List<List<Map<String, Object?>>>> readSheets(
  ImportSource source,
  ExcelType type, {
  required bool headingRow,
}) async {
  final sheets = <List<Map<String, Object?>>>[];
  if (type == ExcelType.xlsx) {
    final reader = await XlsxReader.open(await source.open());
    try {
      for (final sheet in reader.sheets) {
        final collector = _SheetCollector(headingRow);
        await _importRows(
          collector,
          reader.rows(sheet).map((row) => (row.number, row.cells)),
        );
        sheets.add(collector.rows);
      }
    } finally {
      await reader.close();
    }
    return sheets;
  }
  final collector = _SheetCollector(headingRow);
  var number = 0;
  await _importRows(
    collector,
    parseCsv(
      source.read(),
      type == ExcelType.tsv ? CsvSettings.tsv : const CsvSettings(),
    ).map((cells) => (++number, [for (final cell in cells) _csvValue(cell)])),
  );
  return [collector.rows];
}

final class _SheetCollector with WithHeadingRow implements ToCollection {
  _SheetCollector(this.heading);
  final bool heading;
  List<Map<String, Object?>> rows = const [];

  @override
  int headingRow() => heading ? 1 : 0;

  @override
  void collection(List<Map<String, Object?>> rows) => this.rows = rows;
}

Iterable<(Object, SheetInfo)> _selectSheets(
  Object import,
  List<SheetInfo> sheets,
) sync* {
  if (sheets.isEmpty) {
    return;
  }
  SheetInfo? find(Object key) => switch (key) {
    final int index when index >= 0 && index < sheets.length => sheets[index],
    final String name => sheets.where((s) => s.name == name).firstOrNull,
    _ => null,
  };
  if (import is WithMultipleSheetImports) {
    for (final MapEntry(:key, :value) in import.sheets().entries) {
      final sheet = find(key);
      if (sheet == null) {
        throw StateError('The workbook has no sheet $key.');
      }
      yield (value, sheet);
    }
    return;
  }
  final key = import is WithSheetSelection ? import.sheet : 0;
  yield (
    import,
    find(key) ?? (throw StateError('The workbook has no sheet $key.')),
  );
}

/// A CSV field as PhpSpreadsheet's default value binder reads it: numeric
/// text becomes a number, except with a leading zero (`0123`).
Object? _csvValue(String text) {
  if (text.isEmpty) {
    return null;
  }
  if (RegExp(r'^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$')
      .hasMatch(text)) {
    return int.tryParse(text) ?? double.tryParse(text) ?? text;
  }
  return text;
}

Future<void> _importRows(
  Object import,
  Stream<(int, List<Object?>)> rows,
) async {
  if (import is! ToModel && import is! ToCollection && import is! OnEachRow) {
    throw ArgumentError(
      '${import.runtimeType} is not an import: implement ToModel, '
      'ToCollection or OnEachRow.',
    );
  }
  final headingRow = import is WithHeadingRow ? import.headingRow() : 0;
  final startRow = import is WithStartRow ? import.startRow() : headingRow + 1;
  final limit = import is WithLimit ? import.limit() : null;
  final chunkSize = import is WithChunkReading
      ? import.chunkSize
      : import is ToCollection
      ? null
      : import is WithBatchInserts
      ? import.batchSize
      : 1000;
  List<String>? headings;
  var taken = 0;
  var chunk = <ExcelRow>[];

  await for (final (number, cells) in rows) {
    if (number == headingRow) {
      headings = [
        for (var i = 0; i < cells.length; i++) _headingKey(cells[i], i),
      ];
      continue;
    }
    if (number < startRow) {
      continue;
    }
    if (limit != null && taken >= limit) {
      break;
    }
    if (import is SkipsEmptyRows &&
        cells.every(
          (cell) => cell == null || (cell is String && cell.trim().isEmpty),
        )) {
      continue;
    }
    final values = <String, Object?>{};
    final keys = headings;
    if (keys != null) {
      for (var i = 0; i < keys.length; i++) {
        values[keys[i]] = i < cells.length ? cells[i] : null;
      }
      for (var i = keys.length; i < cells.length; i++) {
        values['$i'] = cells[i];
      }
    } else {
      for (var i = 0; i < cells.length; i++) {
        values['$i'] = cells[i];
      }
    }
    taken++;
    chunk.add(ExcelRow(number, values));
    if (chunkSize != null && chunk.length >= chunkSize) {
      await _handle(import, chunk);
      chunk = [];
    }
  }
  if (chunk.isNotEmpty) {
    await _handle(import, chunk);
  }
}

/// Laravel Excel's `slug` heading formatter; an empty heading is keyed by
/// its column index.
String _headingKey(Object? cell, int index) {
  final text = cell == null ? '' : '$cell'.trim();
  if (text.isEmpty) {
    return '$index';
  }
  final slug = Str.slug(text, separator: '_');
  return slug.isEmpty ? '$index' : slug;
}

Future<void> _handle(Object import, List<ExcelRow> rows) async {
  // `import` is narrowed below; these keep its other contracts reachable.
  final Object any = import;
  var valid = rows;
  if (import is WithValidation) {
    final failures = <Failure>[];
    final failed = <int>{};
    final rules = {
      for (final MapEntry(:key, :value) in import.rules().entries)
        key.startsWith('*.') ? key.substring(2) : key: value,
    };
    final messages = any is WithCustomValidationMessages
        ? any.customValidationMessages()
        : const <String, String>{};
    final attributes = any is WithCustomValidationAttributes
        ? any.customValidationAttributes()
        : const <String, String>{};
    for (final row in rows) {
      final errors = await Validator(
        row.values,
        rules,
        messages: {
          for (final MapEntry(:key, :value) in messages.entries)
            key.startsWith('*.') ? key.substring(2) : key: value,
        },
        attributes: {
          for (final MapEntry(:key, :value) in attributes.entries)
            key.startsWith('*.') ? key.substring(2) : key: value,
        },
        container: Container.current,
      ).run();
      for (final MapEntry(:key, :value) in errors.entries) {
        failures.add(Failure(row.index, key, value, row.values));
        failed.add(row.index);
      }
    }
    if (failures.isNotEmpty) {
      if (any is! SkipsOnFailure) {
        throw ExcelValidationException(failures);
      }
      any.onFailure(failures);
      valid = [
        for (final row in rows)
          if (!failed.contains(row.index)) row,
      ];
    }
  }
  switch (import) {
    case ToModel():
      final batch = any is WithBatchInserts ? any.batchSize : 0;
      final pending = <Model>[];
      for (final row in valid) {
        final model = await import.model(row.values);
        if (model == null || model.exists) {
          continue;
        }
        if (batch > 0) {
          pending.add(model);
          if (pending.length >= batch) {
            await _insert(pending);
            pending.clear();
          }
        } else {
          await model.save();
        }
      }
      await _insert(pending);
    case ToCollection():
      await import.collection([for (final row in valid) row.values]);
    case OnEachRow():
      for (final row in valid) {
        await import.onRow(row);
      }
  }
}

/// One `INSERT` per model type, as Laravel Excel's batch inserts do (no
/// model events, attributes as set).
Future<void> _insert(List<Model> models) async {
  final byDefinition = <ModelDefinition<Model>, List<Map<String, Object?>>>{};
  for (final model in models) {
    byDefinition
        .putIfAbsent(model.modelDefinition, () => [])
        .add(Map.of(model.attributes));
  }
  for (final MapEntry(:key, :value) in byDefinition.entries) {
    await key.query().builder.insert(value);
  }
}
