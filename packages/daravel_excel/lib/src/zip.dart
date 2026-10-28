import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// CRC-32 (IEEE 802.3), as ZIP stores it, computed incrementally.
final class Crc32 {
  static final Uint32List _table = () {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c;
    }
    return table;
  }();

  int _crc = 0xFFFFFFFF;

  void add(List<int> bytes) {
    var crc = _crc;
    for (final byte in bytes) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
    }
    _crc = crc;
  }

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Writes a ZIP archive as a stream, entry after entry, without holding an
/// entry in memory: each entry is deflated as it is written, its CRC and
/// sizes follow it in a data descriptor (general purpose bit 3), and the
/// central directory comes last. What XLSX writers that stream do.
final class ZipStreamWriter {
  ZipStreamWriter(this._out);

  /// A writer that collects its bytes, for a producer to [take] them.
  factory ZipStreamWriter.buffered() => ZipStreamWriter(ByteCollector());

  final Sink<List<int>> _out;

  /// The bytes written since the last call, when built [buffered].
  List<List<int>> take() => _out is ByteCollector ? _out.take() : const [];
  final List<_CentralEntry> _entries = [];
  int _offset = 0;

  _EntrySink? _open;

  void _emit(List<int> bytes) {
    if (bytes.isEmpty) {
      return;
    }
    _out.add(bytes);
    _offset += bytes.length;
  }

  /// Starts the entry [name]; write its content to the returned sink and
  /// close it before the next entry.
  ZipEntrySink entry(String name, {DateTime? modified}) {
    if (_open != null) {
      throw StateError('Close the entry ${_open!.name} first.');
    }
    final nameBytes = utf8.encode(name);
    final (time, date) = _dosTime(modified ?? DateTime.now());
    final header = _Bytes()
      ..u32(0x04034b50)
      ..u16(20) // version needed: 2.0
      ..u16(0x0808) // data descriptor follows; UTF-8 name
      ..u16(8) // deflate
      ..u16(time)
      ..u16(date)
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u16(nameBytes.length)
      ..u16(0)
      ..add(nameBytes);
    final offset = _offset;
    _emit(header.bytes);
    return _open = _EntrySink(this, name, nameBytes, offset, time, date);
  }

  void _closeEntry(_EntrySink entry) {
    if (entry.compressedSize > 0xFFFFFFFF || entry.size > 0xFFFFFFFF) {
      throw StateError(
        'ZIP entry ${entry.name} is larger than 4 GiB; ZIP64 is not '
        'supported.',
      );
    }
    final descriptor = _Bytes()
      ..u32(0x08074b50)
      ..u32(entry.crc.value)
      ..u32(entry.compressedSize)
      ..u32(entry.size);
    _emit(descriptor.bytes);
    _entries.add(
      _CentralEntry(
        entry.nameBytes,
        entry.crc.value,
        entry.compressedSize,
        entry.size,
        entry.offset,
        entry.time,
        entry.date,
      ),
    );
    _open = null;
  }

  /// Writes the central directory. The sink given to the constructor is
  /// not closed.
  void finish() {
    if (_open != null) {
      throw StateError('Close the entry ${_open!.name} first.');
    }
    if (_entries.length > 0xFFFF) {
      throw StateError('More than 65 535 ZIP entries need ZIP64.');
    }
    final start = _offset;
    for (final entry in _entries) {
      final header = _Bytes()
        ..u32(0x02014b50)
        ..u16(20) // made by: 2.0
        ..u16(20)
        ..u16(0x0808)
        ..u16(8)
        ..u16(entry.time)
        ..u16(entry.date)
        ..u32(entry.crc)
        ..u32(entry.compressedSize)
        ..u32(entry.size)
        ..u16(entry.name.length)
        ..u16(0)
        ..u16(0)
        ..u16(0)
        ..u16(0)
        ..u32(0)
        ..u32(entry.offset)
        ..add(entry.name);
      _emit(header.bytes);
    }
    final size = _offset - start;
    final end = _Bytes()
      ..u32(0x06054b50)
      ..u16(0)
      ..u16(0)
      ..u16(_entries.length)
      ..u16(_entries.length)
      ..u32(size)
      ..u32(start)
      ..u16(0);
    _emit(end.bytes);
  }

  static (int, int) _dosTime(DateTime when) {
    final t = when.year < 1980 ? DateTime(1980) : when;
    final time = (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
    final date = ((t.year - 1980) << 9) | (t.month << 5) | t.day;
    return (time, date);
  }
}

/// The content of one ZIP entry being written.
abstract interface class ZipEntrySink {
  void add(List<int> bytes);
  void addString(String text);
  void close();
}

final class _EntrySink implements ZipEntrySink {
  _EntrySink(
    this._writer,
    this.name,
    this.nameBytes,
    this.offset,
    this.time,
    this.date,
  ) {
    _deflate = ZLibEncoder(
      raw: true,
      level: 6,
    ).startChunkedConversion(_Counter(this));
  }

  final ZipStreamWriter _writer;
  final String name;
  final List<int> nameBytes;
  final int offset;
  final int time;
  final int date;
  final Crc32 crc = Crc32();
  int size = 0;
  int compressedSize = 0;
  late final ByteConversionSink _deflate;
  bool _closed = false;

  @override
  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Entry $name is closed.');
    }
    crc.add(bytes);
    size += bytes.length;
    _deflate.add(bytes);
  }

  @override
  void addString(String text) => add(utf8.encode(text));

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _deflate.close();
    _writer._closeEntry(this);
  }
}

final class _Counter implements Sink<List<int>> {
  _Counter(this._entry);
  final _EntrySink _entry;

  @override
  void add(List<int> data) {
    _entry.compressedSize += data.length;
    _entry._writer._emit(data);
  }

  @override
  void close() {}
}

/// Collects what a writer or converter writes, until [take]n.
final class ByteCollector implements Sink<List<int>> {
  List<List<int>> _chunks = [];

  @override
  void add(List<int> data) {
    if (data.isNotEmpty) {
      _chunks.add(data);
    }
  }

  @override
  void close() {}

  List<List<int>> take() {
    final taken = _chunks;
    _chunks = [];
    return taken;
  }
}

final class _CentralEntry {
  const _CentralEntry(
    this.name,
    this.crc,
    this.compressedSize,
    this.size,
    this.offset,
    this.time,
    this.date,
  );
  final List<int> name;
  final int crc;
  final int compressedSize;
  final int size;
  final int offset;
  final int time;
  final int date;
}

final class _Bytes {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void u16(int value) => _builder.add([value & 0xFF, (value >> 8) & 0xFF]);

  void u32(int value) => _builder.add([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);

  void add(List<int> bytes) => _builder.add(bytes);

  Uint8List get bytes => _builder.takeBytes();
}

/// Thrown for a file that is not a readable ZIP archive (and so not an
/// XLSX workbook).
final class ZipFormatException implements Exception {
  const ZipFormatException(this.message);
  final String message;
  @override
  String toString() => 'ZipFormatException: $message';
}

/// An entry of a [ZipReader].
final class ZipEntry {
  const ZipEntry._(
    this.name,
    this.method,
    this.compressedSize,
    this.size,
    this._localOffset,
  );
  final String name;
  final int method;
  final int compressedSize;
  final int size;
  final int _localOffset;
}

/// Bytes a [ZipReader] can read at any offset: a file or memory.
abstract interface class RandomAccessSource {
  Future<int> length();
  Future<Uint8List> read(int offset, int length);
  Future<void> close();

  factory RandomAccessSource.bytes(List<int> bytes) = _MemorySource;
  static Future<RandomAccessSource> file(String path) async =>
      _FileSource(await File(path).open());
}

final class _MemorySource implements RandomAccessSource {
  _MemorySource(List<int> bytes)
    : _bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final Uint8List _bytes;

  @override
  Future<int> length() async => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async => Uint8List.sublistView(
    _bytes,
    offset,
    math.min(_bytes.length, offset + length),
  );

  @override
  Future<void> close() async {}
}

final class _FileSource implements RandomAccessSource {
  _FileSource(this._file);
  final RandomAccessFile _file;

  @override
  Future<int> length() => _file.length();

  @override
  Future<Uint8List> read(int offset, int length) async {
    await _file.setPosition(offset);
    return _file.read(length);
  }

  @override
  Future<void> close() => _file.close();
}

/// Reads a ZIP archive's directory and streams its entries inflated, a
/// chunk at a time, so a large sheet never sits in memory whole.
final class ZipReader {
  ZipReader._(this._source, this.entries);

  final RandomAccessSource _source;
  final Map<String, ZipEntry> entries;

  static Future<ZipReader> open(RandomAccessSource source) async {
    final length = await source.length();
    if (length < 22) {
      throw const ZipFormatException('The file is too short to be a ZIP.');
    }
    // The end-of-central-directory record is in the last 64 KiB + 22.
    final tailLength = math.min(length, 0xFFFF + 22);
    final tail = await source.read(length - tailLength, tailLength);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4b &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw const ZipFormatException('No ZIP end-of-central-directory record.');
    }
    final eocd = ByteData.sublistView(tail, end);
    final count = eocd.getUint16(10, Endian.little);
    final dirSize = eocd.getUint32(12, Endian.little);
    final dirOffset = eocd.getUint32(16, Endian.little);
    if (dirOffset == 0xFFFFFFFF || count == 0xFFFF) {
      throw const ZipFormatException('ZIP64 archives are not supported.');
    }
    if (dirOffset + dirSize > length) {
      throw const ZipFormatException('The ZIP central directory is truncated.');
    }
    final dir = await source.read(dirOffset, dirSize);
    final data = ByteData.sublistView(dir);
    final entries = <String, ZipEntry>{};
    var p = 0;
    for (var i = 0; i < count; i++) {
      if (p + 46 > dir.length ||
          data.getUint32(p, Endian.little) != 0x02014b50) {
        throw const ZipFormatException('A ZIP directory entry is malformed.');
      }
      final method = data.getUint16(p + 10, Endian.little);
      final compressed = data.getUint32(p + 20, Endian.little);
      final size = data.getUint32(p + 24, Endian.little);
      final nameLength = data.getUint16(p + 28, Endian.little);
      final extraLength = data.getUint16(p + 30, Endian.little);
      final commentLength = data.getUint16(p + 32, Endian.little);
      final offset = data.getUint32(p + 42, Endian.little);
      final name = utf8.decode(
        dir.sublist(p + 46, p + 46 + nameLength),
        allowMalformed: true,
      );
      entries[name] = ZipEntry._(name, method, compressed, size, offset);
      p += 46 + nameLength + extraLength + commentLength;
    }
    return ZipReader._(source, entries);
  }

  /// The inflated content of [name], in chunks; at most [maxBytes] of it
  /// (a defence against ZIP bombs), or a [ZipFormatException].
  Stream<List<int>> read(String name, {int? maxBytes}) async* {
    final entry =
        entries[name] ??
        (throw ZipFormatException('No entry $name in the ZIP.'));
    final header = await _source.read(entry._localOffset, 30);
    final data = ByteData.sublistView(header);
    if (header.length < 30 || data.getUint32(0, Endian.little) != 0x04034b50) {
      throw ZipFormatException('The local header of $name is malformed.');
    }
    var position =
        entry._localOffset +
        30 +
        data.getUint16(26, Endian.little) +
        data.getUint16(28, Endian.little);
    final end = position + entry.compressedSize;
    // dart:io's chunked inflater is synchronous: each compressed chunk
    // fed in comes out at once, so one chunk is in memory at a time.
    final pending = ByteCollector();
    final Sink<List<int>> inflate = switch (entry.method) {
      0 => pending,
      8 => ZLibDecoder(raw: true).startChunkedConversion(pending),
      _ => throw ZipFormatException(
        'ZIP compression method ${entry.method} of $name is not supported.',
      ),
    };
    var total = 0;
    Iterable<List<int>> drain() sync* {
      for (final chunk in pending.take()) {
        total += chunk.length;
        if (maxBytes != null && total > maxBytes) {
          throw ZipFormatException('$name inflates beyond $maxBytes bytes.');
        }
        yield chunk;
      }
    }

    while (position < end) {
      final chunk = await _source.read(
        position,
        math.min(64 * 1024, end - position),
      );
      if (chunk.isEmpty) {
        throw ZipFormatException('$name is truncated.');
      }
      position += chunk.length;
      inflate.add(chunk);
      yield* Stream.fromIterable(drain());
    }
    inflate.close();
    yield* Stream.fromIterable(drain());
  }

  Future<void> close() => _source.close();
}
