import 'dart:convert';

import 'package:xml/xml_events.dart';

import 'cells.dart';
import 'zip.dart';

/// A sheet row as read: its 1-based [number] in the sheet and its cells
/// from column A, `null` for empty ones.
final class SheetRow {
  const SheetRow(this.number, this.cells);
  final int number;
  final List<Object?> cells;
}

/// A sheet of a workbook: its [name] and where its XML lives.
final class SheetInfo {
  const SheetInfo(this.name, this._path);
  final String name;
  final String _path;
}

/// Reads an XLSX workbook: its sheets in order, and each sheet's rows as a
/// stream. Numbers come as `int` or `double` (a date cell is its serial
/// number, as Laravel Excel returns it; see [ExcelDate]), booleans as
/// `bool`, text as `String`, a formula as its cached result.
final class XlsxReader {
  XlsxReader._(this._zip, this.sheets, this._shared);

  final ZipReader _zip;
  final List<SheetInfo> sheets;
  final List<String> _shared;

  /// The largest part loaded whole (workbook, relationships, shared
  /// strings): a defence against ZIP bombs.
  static const int maxPartBytes = 256 * 1024 * 1024;

  static Future<XlsxReader> open(RandomAccessSource source) async {
    final zip = await ZipReader.open(source);
    if (!zip.entries.containsKey('xl/workbook.xml')) {
      await zip.close();
      throw const ZipFormatException(
        'Not an XLSX workbook: xl/workbook.xml is missing.',
      );
    }
    final rels = <String, (String, String)>{};
    if (zip.entries.containsKey('xl/_rels/workbook.xml.rels')) {
      await for (final event in _events(zip, 'xl/_rels/workbook.xml.rels')) {
        if (event is XmlStartElementEvent &&
            _local(event.name) == 'Relationship') {
          final id = _attr(event, 'Id');
          final target = _attr(event, 'Target');
          final type = _attr(event, 'Type') ?? '';
          if (id != null && target != null) {
            rels[id] = (type, _resolve(target));
          }
        }
      }
    }
    final sheets = <SheetInfo>[];
    await for (final event in _events(zip, 'xl/workbook.xml')) {
      if (event is XmlStartElementEvent && _local(event.name) == 'sheet') {
        final id = _attr(event, 'id');
        final path = id == null ? null : rels[id]?.$2;
        if (path != null) {
          sheets.add(
            SheetInfo(
              _attr(event, 'name') ?? 'Sheet${sheets.length + 1}',
              path,
            ),
          );
        }
      }
    }
    final shared = <String>[];
    final sharedPath = rels.values
        .where((rel) => rel.$1.endsWith('/sharedStrings'))
        .map((rel) => rel.$2)
        .firstOrNull;
    if (sharedPath != null && zip.entries.containsKey(sharedPath)) {
      var text = StringBuffer();
      var inText = false;
      var phonetic = 0;
      await for (final event in _events(zip, sharedPath)) {
        switch (event) {
          case XmlStartElementEvent(:final name, :final isSelfClosing):
            switch (_local(name)) {
              case 'si':
                text = StringBuffer();
                if (isSelfClosing) {
                  shared.add('');
                }
              case 'rPh':
                if (!isSelfClosing) phonetic++;
              case 't':
                inText = !isSelfClosing;
            }
          case XmlEndElementEvent(:final name):
            switch (_local(name)) {
              case 'si':
                shared.add(text.toString());
              case 'rPh':
                phonetic--;
              case 't':
                inText = false;
            }
          case XmlTextEvent(:final value) when inText && phonetic == 0:
            text.write(value);
          case XmlCDATAEvent(:final value) when inText && phonetic == 0:
            text.write(value);
          default:
        }
      }
    }
    return XlsxReader._(zip, sheets, shared);
  }

  /// The rows of [sheet], in order, with their row numbers.
  Stream<SheetRow> rows(SheetInfo sheet) async* {
    var cells = <Object?>[];
    var rowNumber = 0;
    var column = 0;
    String? type;
    var valueText = StringBuffer();
    var inline = StringBuffer();
    var inValue = false;
    var inInlineText = false;
    var hasValue = false;

    Object? cellValue() {
      final raw = valueText.toString();
      switch (type) {
        case 's':
          final index = int.tryParse(raw.trim());
          return index != null && index >= 0 && index < _shared.length
              ? _shared[index]
              : null;
        case 'inlineStr':
          return inline.toString();
        case 'str' || 'e':
          return raw;
        case 'b':
          return raw.trim() == '1';
        default:
          if (!hasValue) return null;
          final text = raw.trim();
          return int.tryParse(text) ?? double.tryParse(text) ?? text;
      }
    }

    await for (final event in _events(_zip, sheet._path)) {
      switch (event) {
        case XmlStartElementEvent(:final name, :final isSelfClosing):
          switch (_local(name)) {
            case 'row':
              rowNumber =
                  int.tryParse(_attr(event, 'r') ?? '') ?? rowNumber + 1;
              cells = <Object?>[];
              column = 0;
              if (isSelfClosing) {
                yield SheetRow(rowNumber, cells);
              }
            case 'c':
              final ref = _attr(event, 'r');
              column = ref == null
                  ? column
                  : columnIndex(ref.replaceAll(RegExp('[0-9]'), ''));
              type = _attr(event, 't');
              valueText = StringBuffer();
              inline = StringBuffer();
              hasValue = false;
              if (isSelfClosing) {
                column++;
              }
            case 'v':
              inValue = !isSelfClosing;
              hasValue = true;
            case 't':
              inInlineText = !isSelfClosing;
          }
        case XmlEndElementEvent(:final name):
          switch (_local(name)) {
            case 'v':
              inValue = false;
            case 't':
              inInlineText = false;
            case 'c':
              final cell = cellValue();
              if (cell != null) {
                while (cells.length < column) {
                  cells.add(null);
                }
                cells.add(cell);
              }
              column++;
            case 'row':
              yield SheetRow(rowNumber, cells);
          }
        case XmlTextEvent(value: final text) ||
            XmlCDATAEvent(value: final text):
          if (inValue) {
            valueText.write(text);
          }
          if (inInlineText) {
            inline.write(text);
          }
        default:
      }
    }
  }

  Future<void> close() => _zip.close();

  static Stream<XmlEvent> _events(ZipReader zip, String path) => zip
      .read(path, maxBytes: path.contains('worksheets/') ? null : maxPartBytes)
      .transform(const Utf8Decoder(allowMalformed: true))
      .toXmlEvents()
      .normalizeEvents()
      .flatten();

  static String _local(String name) {
    final colon = name.indexOf(':');
    return colon < 0 ? name : name.substring(colon + 1);
  }

  static String? _attr(XmlStartElementEvent event, String local) {
    for (final attribute in event.attributes) {
      if (_local(attribute.name) == local) {
        return attribute.value;
      }
    }
    return null;
  }

  /// A relationship target relative to `xl/`, or absolute from the root.
  static String _resolve(String target) =>
      target.startsWith('/') ? target.substring(1) : 'xl/$target';
}
