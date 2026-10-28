import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'cells.dart';
import 'concerns.dart';
import 'csv.dart';
import 'xlsx_writer.dart';

/// The file types Daravel Excel writes and reads.
enum ExcelType {
  xlsx(
    'Xlsx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ),
  csv('Csv', 'text/csv'),
  tsv('Tsv', 'text/tab-separated-values');

  const ExcelType(this.label, this.contentType);

  /// Laravel Excel's writer type name (`Excel::XLSX`).
  final String label;
  final String contentType;

  /// The type of [fileName] by its extension; `null` when unknown.
  static ExcelType? fromFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final extension = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'xlsx' => ExcelType.xlsx,
      'csv' || 'txt' => ExcelType.csv,
      'tsv' => ExcelType.tsv,
      _ => null,
    };
  }
}

/// Writes [export] as [type], as a stream that produces the file while it
/// is read: a query is read a chunk at a time, and nothing is produced
/// faster than the reader (an HTTP client, a disk) consumes it.
///
/// The work runs in the zone this is called in, so a query built in a
/// request runs against the request's database and container.
Stream<List<int>> exportStream(Object export, ExcelType type) {
  final zone = Zone.current;
  StreamSubscription<List<int>>? subscription;
  late final StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    onListen: () {
      subscription = zone.run(
        () => _produce(export, type).listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        ),
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () => subscription?.cancel(),
  );
  return controller.stream;
}

Stream<List<int>> _produce(Object export, ExcelType type) async* {
  final sheets = export is WithMultipleSheets ? export.sheets() : [export];
  if (type == ExcelType.xlsx) {
    final writer = XlsxWriter();
    for (final sheet in sheets) {
      writer.startSheet(
        sheet is WithTitle ? sheet.title() : 'Worksheet',
        formats: sheet is WithColumnFormatting
            ? _byColumn(sheet.columnFormats())
            : const {},
        widths: sheet is WithColumnWidths
            ? _byColumn(sheet.columnWidths())
            : const {},
      );
      var n = 0;
      await for (final row in sheetRows(sheet)) {
        writer.addRow(row);
        if (++n % 500 == 0) {
          yield* Stream.fromIterable(writer.take());
        }
      }
      writer.endSheet();
      yield* Stream.fromIterable(writer.take());
    }
    writer.finish();
    yield* Stream.fromIterable(writer.take());
    return;
  }
  // CSV holds one sheet: the first, as Laravel Excel writes the active one.
  final sheet = sheets.first;
  final settings = sheet is WithCustomCsvSettings
      ? sheet.getCsvSettings()
      : export is WithCustomCsvSettings
      ? export.getCsvSettings()
      : (type == ExcelType.tsv ? CsvSettings.tsv : const CsvSettings());
  if (settings.useBom) {
    yield const [0xEF, 0xBB, 0xBF];
  }
  final buffer = StringBuffer();
  await for (final row in sheetRows(sheet)) {
    buffer.write(csvLine([for (final cell in row) csvText(cell)], settings));
    if (buffer.length > 64 * 1024) {
      yield utf8.encode(buffer.toString());
      buffer.clear();
    }
  }
  if (buffer.isNotEmpty) {
    yield utf8.encode(buffer.toString());
  }
}

/// The rows of one sheet of an export: its headings, then its source rows
/// mapped to cells.
Stream<List<Object?>> sheetRows(Object sheet) async* {
  if (sheet is WithHeadings) {
    final headings = sheet.headings();
    if (headings.isNotEmpty && headings.first is List) {
      for (final row in headings) {
        yield List<Object?>.from(row! as List);
      }
    } else if (headings.isNotEmpty) {
      yield headings;
    }
  }
  await for (final item in _source(sheet)) {
    final mapped = sheet is WithMapping
        ? await sheet.map(item)
        : _defaultCells(item);
    if (mapped.isNotEmpty && mapped.first is List) {
      for (final row in mapped) {
        yield List<Object?>.from(row! as List);
      }
    } else {
      yield mapped;
    }
  }
}

Stream<Object?> _source(Object sheet) async* {
  switch (sheet) {
    case FromQuery():
      final Object any = sheet;
      final size = any is WithCustomChunkSize ? any.chunkSize : 1000;
      yield* _queryRows(sheet.query(), size);
    case FromCollection():
      yield* Stream.fromIterable(await sheet.collection());
    case FromGenerator():
      yield* sheet.generator();
    default:
      throw ArgumentError(
        '${sheet.runtimeType} is not an export: implement FromQuery, '
        'FromCollection, FromGenerator or WithMultipleSheets.',
      );
  }
}

/// A query's rows, [size] at a time, as a stream that waits while its
/// reader is paused.
Stream<Object?> _queryRows(Object query, int size) {
  late final StreamController<Object?> controller;
  Completer<void>? resumed;
  Future<void> push(Iterable<Object?> rows) async {
    for (final row in rows) {
      controller.add(row);
    }
    while (controller.isPaused) {
      await (resumed ??= Completer<void>()).future;
    }
  }

  controller = StreamController<Object?>(
    onListen: () async {
      try {
        switch (query) {
          case ModelQuery<Model>():
            await query.chunk(size, (models, _) => push(models));
          case QueryBuilder():
            await query.chunk(size, (rows, _) => push(rows));
          default:
            throw ArgumentError(
              'FromQuery.query() must return a ModelQuery or a QueryBuilder, '
              'not ${query.runtimeType}.',
            );
        }
      } on Object catch (error, stack) {
        controller.addError(error, stack);
      }
      await controller.close();
    },
    onResume: () {
      resumed?.complete();
      resumed = null;
    },
  );
  return controller.stream;
}

List<Object?> _defaultCells(Object? item) => switch (item) {
  Model() => item.toJson().values.toList(),
  Map<Object?, Object?>() => item.values.toList(),
  List<Object?>() => item,
  _ => [item],
};

/// Column letters or ranges (`D`, `B:D`, `D2:D90`) to zero-based indexes.
Map<int, V> _byColumn<V>(Map<String, V> byLetter) {
  final out = <int, V>{};
  for (final MapEntry(:key, :value) in byLetter.entries) {
    final parts = key.split(':').map((p) => p.replaceAll(RegExp('[0-9]'), ''));
    final indexes = parts.map(columnIndex).toList();
    for (var i = indexes.first; i <= indexes.last; i++) {
      out[i] = value;
    }
  }
  return out;
}

/// A cell as CSV text: booleans as `TRUE`/`FALSE` and dates as
/// `yyyy-mm-dd hh:mm:ss`, as PhpSpreadsheet formats them; whole doubles
/// without `.0`.
String csvText(Object? cell) => switch (cell) {
  null => '',
  bool() => cell ? 'TRUE' : 'FALSE',
  double()
      when cell.isFinite &&
          cell == cell.truncateToDouble() &&
          cell.abs() < 1e15 =>
    cell.toInt().toString(),
  DateTime() => _dateText(cell),
  Enum() => cell.name,
  _ => '$cell',
};

String _dateText(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date =
      '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-${two(value.day)}';
  if (value.hour == 0 && value.minute == 0 && value.second == 0) {
    return date;
  }
  return '$date ${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}
