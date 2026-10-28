import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';

import 'concerns.dart';
import 'exporter.dart';
import 'importer.dart';

/// Laravel Excel's `Excel` facade: exports to a download, a disk or bytes,
/// and imports from an upload, a disk or bytes.
///
/// ```dart
/// router.get('/students.xlsx', (_) => Excel.download(StudentsExport(), 'students.xlsx'));
/// await Excel.import(StudentsImport(), request.file('spreadsheet')!);
/// ```
abstract final class Excel {
  /// A streamed download of [export] named [fileName]; its type follows
  /// the extension unless [type] says otherwise.
  static Response download(
    Object export,
    String fileName, {
    ExcelType? type,
    Map<String, String> headers = const {},
  }) {
    final resolved = _type(fileName, type);
    final quoted = fileName.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return Response.stream(
      exportStream(export, resolved),
      contentType: resolved.contentType,
      headers: {
        'content-disposition':
            'attachment; filename="$quoted"; filename*=UTF-8\'\'${Uri.encodeComponent(fileName)}',
        'cache-control': 'no-store',
        ...headers,
      },
    );
  }

  /// Writes [export] to [path] on [disk] (the default disk), streamed:
  /// `Storage.putStream` holds a part at a time, on S3 too.
  static Future<void> store(
    Object export,
    String path, {
    String? disk,
    ExcelType? type,
  }) =>
      Storage.disk(disk)
          .putStream(path, exportStream(export, _type(path, type)));

  /// The file of [export] as bytes, in memory.
  static Future<Uint8List> raw(Object export, ExcelType type) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in exportStream(export, type)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// The file of [export] as a stream, produced as it is read.
  static Stream<List<int>> stream(Object export, ExcelType type) =>
      exportStream(export, type);

  /// Imports [source]: an [UploadedFile], a path on [disk] (a `String`), or
  /// bytes; its type follows its name unless [type] says otherwise. The
  /// rows are handled in one transaction: a failure leaves nothing behind.
  static Future<void> import(
    Object import,
    Object source, {
    String? disk,
    ExcelType? type,
    bool transaction = true,
  }) async {
    final (input, name, cleanup) = await _source(source, disk);
    try {
      await runImport(
        import,
        input,
        _type(name, type),
        transaction: transaction,
      );
    } finally {
      await cleanup();
    }
  }

  /// The rows of every sheet of [source] (Laravel Excel's `toArray`): a
  /// list per sheet of rows keyed by heading with [WithHeadingRow], by
  /// column index otherwise.
  static Future<List<List<Map<String, Object?>>>> toArray(
    Object source, {
    bool headingRow = false,
    String? disk,
    ExcelType? type,
  }) async {
    final (input, name, cleanup) = await _source(source, disk);
    try {
      return await readSheets(input, _type(name, type), headingRow: headingRow);
    } finally {
      await cleanup();
    }
  }

  static ExcelType _type(String name, ExcelType? type) =>
      type ??
      ExcelType.fromFileName(name) ??
      (throw ArgumentError(
        'Cannot tell the file type of "$name": pass type: ExcelType.xlsx '
        'or ExcelType.csv.',
      ));

  static Future<(ImportSource, String, Future<void> Function())> _source(
    Object source,
    String? disk,
  ) async {
    Future<void> nothing() async {}
    switch (source) {
      case UploadedFile():
        final path = source.path;
        return (
          path != null
              ? ImportSource.path(path)
              : ImportSource.bytes(await source.bytes()),
          source.clientName,
          nothing,
        );
      case String():
        // A file on a disk: copied to a temporary file, since an XLSX is
        // read from its end (the ZIP directory) first.
        final temp = await Directory.systemTemp.createTemp('daravel_excel_');
        final file = File('${temp.path}${Platform.pathSeparator}import');
        final sink = file.openWrite();
        await sink.addStream(Storage.disk(disk).readStream(source));
        await sink.close();
        return (
          ImportSource.path(file.path),
          source,
          () => temp.delete(recursive: true),
        );
      case List<int>():
        return (ImportSource.bytes(source), '', nothing);
      default:
        throw ArgumentError(
          'Excel.import reads an UploadedFile, a path on a disk or bytes, '
          'not ${source.runtimeType}.',
        );
    }
  }
}
