import 'dart:typed_data';

/// A Zstandard frame that is damaged, or uses what Teobiefy never sends.
final class ZstdFormatException implements Exception {
  const ZstdFormatException(this.message);
  final String message;
  @override
  String toString() => 'ZstdFormatException: $message';
}

/// The frame decompresses to more than the limit it was given.
final class ZstdTooLargeException implements Exception {
  const ZstdTooLargeException();
}

const int _magic = 0xFD2FB528;
const int _maxBlockSize = 128 * 1024;

/// Decompresses one Zstandard frame (RFC 8878), for requests from clients
/// using `ext-zstd` or a mobile library. Pure Dart, so the server stays one
/// binary.
///
/// All output is kept, so back references need no ring buffer, and it stops
/// at [maxOutput] before growing further: a bomb costs that much and no more.
/// Dictionaries are refused: Teobiefy does not use them.
Uint8List zstdDecompress(Uint8List frame, {required int maxOutput}) {
  try {
    return _FrameDecoder(frame, maxOutput).decode();
  } on RangeError {
    // A state or index a damaged table led outside its bounds.
    throw const ZstdFormatException('Frame is damaged.');
  }
}

Never _bad(String message) => throw ZstdFormatException(message);

/// Index of the highest set bit.
int _highBit(int value) => value.bitLength - 1;

/// [count] bits of [source] from bit [offset], least significant first.
int _bits(Uint8List source, int offset, int count) {
  var result = 0;
  var done = 0;
  var position = offset;
  while (done < count) {
    final bit = position & 7;
    final take = 8 - bit < count - done ? 8 - bit : count - done;
    final index = position >> 3;
    if (index >= source.length) {
      _bad('Bitstream overrun.');
    }
    result |= ((source[index] >> bit) & ((1 << take) - 1)) << done;
    done += take;
    position += take;
  }
  return result;
}

/// A stream read from its end towards its start. The last byte carries a
/// marker bit above the data, and reading past the start yields zeros.
final class _BackwardBits {
  _BackwardBits(this.source) {
    if (source.isEmpty || source.last == 0) {
      _bad('Bitstream has no end marker.');
    }
    offset = source.length * 8 - (8 - _highBit(source.last));
  }

  final Uint8List source;
  late int offset;

  int read(int count) {
    if (count == 0) {
      return 0;
    }
    offset -= count;
    if (offset >= 0) {
      return _bits(source, offset, count);
    }
    final available = count + offset;
    if (available <= 0) {
      return 0;
    }
    return _bits(source, 0, available) << -offset;
  }
}

/// An FSE decoding table.
final class _Fse {
  _Fse(this.accuracy, this.symbols, this.bits, this.base);

  /// One state, as `RLE_Mode` sends: always [symbol], reading nothing.
  factory _Fse.single(int symbol) =>
      _Fse(0, Uint8List(1)..[0] = symbol, Uint8List(1), Uint16List(1));

  /// The table of a normalized distribution (`-1` is a less than 1 count).
  factory _Fse.from(List<int> counts, int accuracy) {
    final size = 1 << accuracy;
    final symbols = Uint8List(size);
    final next = List<int>.filled(counts.length, 0);
    var high = size;
    for (var s = 0; s < counts.length; s++) {
      if (counts[s] == -1) {
        symbols[--high] = s;
        next[s] = 1;
      }
    }
    final step = (size >> 1) + (size >> 3) + 3;
    final mask = size - 1;
    var position = 0;
    for (var s = 0; s < counts.length; s++) {
      if (counts[s] <= 0) {
        continue;
      }
      next[s] = counts[s];
      for (var i = 0; i < counts[s]; i++) {
        symbols[position] = s;
        do {
          position = (position + step) & mask;
        } while (position >= high);
      }
    }
    if (position != 0) {
      _bad('FSE distribution does not fill its table.');
    }
    final bits = Uint8List(size);
    final base = Uint16List(size);
    for (var i = 0; i < size; i++) {
      final symbol = symbols[i];
      final state = next[symbol]++;
      if (state == 0) {
        _bad('FSE distribution is inconsistent.');
      }
      bits[i] = accuracy - _highBit(state);
      base[i] = (state << bits[i]) - size;
    }
    return _Fse(accuracy, symbols, bits, base);
  }

  final int accuracy;
  final Uint8List symbols;
  final Uint8List bits;
  final Uint16List base;
}

/// Reads an FSE table description at [start]; answers it and where it ends.
(_Fse, int) _readFse(
  Uint8List source,
  int start,
  int maxAccuracy,
  int maxSymbols,
) {
  var bit = start * 8;
  final accuracy = 5 + _bits(source, bit, 4);
  bit += 4;
  if (accuracy > maxAccuracy) {
    _bad('FSE accuracy is too high.');
  }
  final counts = <int>[];
  var remaining = 1 << accuracy;
  while (remaining > 0 && counts.length < maxSymbols) {
    final width = _highBit(remaining + 1) + 1;
    var value = _bits(source, bit, width);
    bit += width;
    final lowerMask = (1 << (width - 1)) - 1;
    final threshold = (1 << width) - 1 - (remaining + 1);
    if ((value & lowerMask) < threshold) {
      bit--;
      value &= lowerMask;
    } else if (value > lowerMask) {
      value -= threshold;
    }
    final count = value - 1;
    counts.add(count);
    remaining -= count.abs();
    if (count == 0) {
      while (true) {
        final repeat = _bits(source, bit, 2);
        bit += 2;
        for (var i = 0; i < repeat && counts.length < maxSymbols; i++) {
          counts.add(0);
        }
        if (repeat != 3) {
          break;
        }
      }
    }
  }
  if (remaining != 0) {
    _bad('FSE distribution does not add up.');
  }
  return (_Fse.from(counts, accuracy), (bit + 7) >> 3);
}

/// A Huffman decoding table of `maxBits` wide states.
final class _Huffman {
  _Huffman(this.maxBits, this.symbols, this.bits);

  factory _Huffman.fromWeights(List<int> weights) {
    // With the implied last weight: 256 symbols at most.
    if (weights.length > 255) {
      _bad('Too many Huffman weights.');
    }
    var sum = 0;
    for (final weight in weights) {
      if (weight > 12) {
        _bad('Huffman weight is too high.');
      }
      if (weight > 0) {
        sum += 1 << (weight - 1);
      }
    }
    if (sum == 0) {
      _bad('Huffman weights are empty.');
    }
    final maxBits = _highBit(sum) + 1;
    if (maxBits > 11) {
      _bad('Huffman code is too long.');
    }
    final left = (1 << maxBits) - sum;
    if (left & (left - 1) != 0) {
      _bad('Huffman weights do not complete a tree.');
    }
    final all = [...weights, _highBit(left) + 1];
    final lengths = [for (final w in all) w > 0 ? maxBits + 1 - w : 0];
    final rankCount = List<int>.filled(maxBits + 2, 0);
    for (final length in lengths) {
      rankCount[length]++;
    }
    final size = 1 << maxBits;
    final symbols = Uint8List(size);
    final bits = Uint8List(size);
    final rankIndex = List<int>.filled(maxBits + 2, 0);
    for (var i = maxBits; i >= 1; i--) {
      rankIndex[i - 1] = rankIndex[i] + rankCount[i] * (1 << (maxBits - i));
      bits.fillRange(rankIndex[i], rankIndex[i - 1], i);
    }
    if (rankIndex[0] != size) {
      _bad('Huffman table is incomplete.');
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length != 0) {
        final span = 1 << (maxBits - length);
        symbols.fillRange(rankIndex[length], rankIndex[length] + span, symbol);
        rankIndex[length] += span;
      }
    }
    return _Huffman(maxBits, symbols, bits);
  }

  final int maxBits;
  final Uint8List symbols;
  final Uint8List bits;

  /// Decodes one stream into [out], from [start] up to [end].
  void decode(Uint8List stream, Uint8List out, int start, int end) {
    final reader = _BackwardBits(stream);
    final mask = (1 << maxBits) - 1;
    var state = reader.read(maxBits);
    var position = start;
    while (reader.offset > -maxBits) {
      if (position >= end) {
        _bad('Huffman stream is too long.');
      }
      out[position++] = symbols[state];
      final width = bits[state];
      state = ((state << width) + reader.read(width)) & mask;
    }
    if (reader.offset != -maxBits || position != end) {
      _bad('Huffman stream has the wrong length.');
    }
  }
}

/// The Huffman description of a compressed literals section.
(_Huffman, int) _readHuffman(Uint8List source, int start, int end) {
  if (start >= end) {
    _bad('Huffman description is missing.');
  }
  final header = source[start];
  var offset = start + 1;
  final weights = <int>[];
  if (header >= 128) {
    final count = header - 127;
    final size = (count + 1) >> 1;
    if (offset + size > end) {
      _bad('Huffman weights are cut short.');
    }
    for (var i = 0; i < count; i++) {
      final byte = source[offset + (i >> 1)];
      weights.add(i.isEven ? byte >> 4 : byte & 15);
    }
    offset += size;
  } else {
    final limit = offset + header;
    if (header == 0 || limit > end) {
      _bad('Huffman weights are cut short.');
    }
    final (table, tableEnd) = _readFse(source, offset, 6, 256);
    if (tableEnd >= limit) {
      _bad('Huffman weights have no data.');
    }
    final reader = _BackwardBits(
      Uint8List.sublistView(source, tableEnd, limit),
    );
    var first = reader.read(table.accuracy);
    var second = reader.read(table.accuracy);
    while (true) {
      weights.add(table.symbols[first]);
      first = table.base[first] + reader.read(table.bits[first]);
      if (reader.offset < 0) {
        weights.add(table.symbols[second]);
        break;
      }
      weights.add(table.symbols[second]);
      second = table.base[second] + reader.read(table.bits[second]);
      if (reader.offset < 0) {
        weights.add(table.symbols[first]);
        break;
      }
      if (weights.length > 254) {
        _bad('Too many Huffman weights.');
      }
    }
    offset = limit;
  }
  return (_Huffman.fromWeights(weights), offset);
}

const List<int> _llBase = [
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  18,
  20,
  22,
  24,
  28, //
  32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
];
const List<int> _llExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
  3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
];
const List<int> _mlBase = [
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23, //
  24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, //
  67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
];
const List<int> _mlExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, //
  4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
];

final _Fse _llDefault = _Fse.from(const [
  4,
  3,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  3, //
  2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
], 6);
final _Fse _ofDefault = _Fse.from(const [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1, -1,
], 5);
final _Fse _mlDefault = _Fse.from(const [
  1,
  4,
  3,
  2,
  2,
  2,
  2,
  2,
  2,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1, //
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  -1,
  -1,
  -1,
  -1,
  -1, //
  -1, -1,
], 6);

final class _FrameDecoder {
  _FrameDecoder(this.source, this.maxOutput);

  final Uint8List source;
  final int maxOutput;

  Uint8List _out = Uint8List(4096);
  int _length = 0;
  int _offset = 0;

  // What a later block may reuse.
  _Huffman? _huffman;
  _Fse? _ll;
  _Fse? _of;
  _Fse? _ml;
  final List<int> _repeat = [1, 4, 8];

  int _byte() {
    if (_offset >= source.length) {
      _bad('Frame is cut short.');
    }
    return source[_offset++];
  }

  int _little(int count) {
    if (_offset + count > source.length) {
      _bad('Frame is cut short.');
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= source[_offset + i] << (8 * i);
    }
    _offset += count;
    return value;
  }

  void _reserve(int extra) {
    final needed = _length + extra;
    if (needed > maxOutput) {
      throw const ZstdTooLargeException();
    }
    if (needed > _out.length) {
      var capacity = _out.length * 2;
      while (capacity < needed) {
        capacity *= 2;
      }
      _out = Uint8List(capacity < maxOutput ? capacity : maxOutput)
        ..setRange(0, _length, _out);
    }
  }

  Uint8List decode() {
    if (_little(4) != _magic) {
      _bad('Not a Zstandard frame.');
    }
    final descriptor = _byte();
    final fcsFlag = descriptor >> 6;
    final single = descriptor & 0x20 != 0;
    final hasChecksum = descriptor & 0x04 != 0;
    if (descriptor & 0x08 != 0) {
      _bad('Reserved frame bit is set.');
    }
    if (descriptor & 3 != 0) {
      _bad('Dictionaries are not supported.');
    }
    if (!single) {
      _byte();
    }
    final contentSize = switch (fcsFlag) {
      0 => single ? _little(1) : null,
      1 => _little(2) + 256,
      2 => _little(4),
      _ => _little(8),
    };
    if (contentSize != null && (contentSize < 0 || contentSize > maxOutput)) {
      throw const ZstdTooLargeException();
    }
    while (_block()) {}
    if (contentSize != null && contentSize != _length) {
      _bad('Frame content has the wrong size.');
    }
    final content = Uint8List.sublistView(_out, 0, _length);
    if (hasChecksum) {
      final expected = _little(4);
      if (xxh64(content) & 0xFFFFFFFF != expected) {
        _bad('Frame checksum does not match.');
      }
    }
    if (_offset != source.length) {
      _bad('Data after the frame.');
    }
    return content;
  }

  /// Decodes one block; answers whether another follows.
  bool _block() {
    final header = _little(3);
    final type = (header >> 1) & 3;
    final size = header >> 3;
    switch (type) {
      case 0:
        if (_offset + size > source.length) {
          _bad('Frame is cut short.');
        }
        _reserve(size);
        _out.setRange(_length, _length + size, source, _offset);
        _length += size;
        _offset += size;
      case 1:
        final value = _byte();
        _reserve(size);
        _out.fillRange(_length, _length + size, value);
        _length += size;
      case 2:
        if (size > _maxBlockSize || _offset + size > source.length) {
          _bad('Block is too large or cut short.');
        }
        _compressed(_offset + size);
        _offset += size;
      default:
        _bad('Reserved block type.');
    }
    return header & 1 == 0;
  }

  void _compressed(int end) {
    final block = Uint8List.sublistView(source, 0, end);
    final (literals, next) = _literals(block, _offset, end);
    _sequences(block, next, end, literals);
  }

  (Uint8List, int) _literals(Uint8List block, int start, int end) {
    if (start >= end) {
      _bad('Block has no literals section.');
    }
    final first = block[start];
    final type = first & 3;
    final format = (first >> 2) & 3;
    int header(int bytes) {
      if (start + bytes > end) {
        _bad('Literals header is cut short.');
      }
      var value = 0;
      for (var i = 0; i < bytes; i++) {
        value |= block[start + i] << (8 * i);
      }
      return value;
    }

    if (type < 2) {
      final (headerSize, regenerated) = switch (format) {
        1 => (2, header(2) >> 4),
        3 => (3, header(3) >> 4),
        _ => (1, first >> 3),
      };
      if (regenerated > _maxBlockSize) {
        _bad('Literals are too large.');
      }
      final from = start + headerSize;
      if (type == 1) {
        if (from >= end) {
          _bad('Literals are cut short.');
        }
        return (
          Uint8List(regenerated)..fillRange(0, regenerated, block[from]),
          from + 1,
        );
      }
      if (from + regenerated > end) {
        _bad('Literals are cut short.');
      }
      return (
        Uint8List.sublistView(block, from, from + regenerated),
        from + regenerated,
      );
    }
    final (headerSize, sizeBits) = switch (format) {
      0 || 1 => (3, 10),
      2 => (4, 14),
      _ => (5, 18),
    };
    final value = header(headerSize);
    final mask = (1 << sizeBits) - 1;
    final regenerated = (value >> 4) & mask;
    final compressed = (value >> (4 + sizeBits)) & mask;
    if (regenerated > _maxBlockSize) {
      _bad('Literals are too large.');
    }
    final from = start + headerSize;
    final to = from + compressed;
    if (to > end) {
      _bad('Literals are cut short.');
    }
    var cursor = from;
    if (type == 2) {
      final (table, tableEnd) = _readHuffman(block, from, to);
      _huffman = table;
      cursor = tableEnd;
    }
    final huffman = _huffman ?? _bad('Treeless literals with no earlier tree.');
    final out = Uint8List(regenerated);
    if (format == 0) {
      huffman.decode(
        Uint8List.sublistView(block, cursor, to),
        out,
        0,
        regenerated,
      );
      return (out, to);
    }
    if (cursor + 6 > to) {
      _bad('Literals jump table is cut short.');
    }
    final one = block[cursor] | block[cursor + 1] << 8;
    final two = block[cursor + 2] | block[cursor + 3] << 8;
    final three = block[cursor + 4] | block[cursor + 5] << 8;
    final s1 = cursor + 6;
    final s2 = s1 + one;
    final s3 = s2 + two;
    final s4 = s3 + three;
    if (s4 > to) {
      _bad('Literals streams are cut short.');
    }
    final part = (regenerated + 3) >> 2;
    if (part * 3 > regenerated) {
      _bad('Literals are too short for four streams.');
    }
    huffman
      ..decode(Uint8List.sublistView(block, s1, s2), out, 0, part)
      ..decode(Uint8List.sublistView(block, s2, s3), out, part, part * 2)
      ..decode(Uint8List.sublistView(block, s3, s4), out, part * 2, part * 3)
      ..decode(
        Uint8List.sublistView(block, s4, to),
        out,
        part * 3,
        regenerated,
      );
    return (out, to);
  }

  _Fse _table(
    int mode,
    Uint8List block,
    int end,
    _Fse fallback,
    _Fse? previous,
    int maxAccuracy,
    int maxSymbols,
    void Function(int next) moved,
    int cursor,
  ) {
    switch (mode) {
      case 0:
        return fallback;
      case 1:
        if (cursor >= end) {
          _bad('Sequences section is cut short.');
        }
        moved(cursor + 1);
        return _Fse.single(block[cursor]);
      case 2:
        final (table, next) = _readFse(block, cursor, maxAccuracy, maxSymbols);
        if (next > end) {
          _bad('Sequences section is cut short.');
        }
        moved(next);
        return table;
      default:
        return previous ?? _bad('Repeat mode with no earlier table.');
    }
  }

  void _sequences(Uint8List block, int start, int end, Uint8List literals) {
    if (start >= end) {
      _bad('Block has no sequences section.');
    }
    var cursor = start;
    final first = block[cursor++];
    int count;
    if (first < 128) {
      count = first;
    } else if (first < 255) {
      if (cursor >= end) {
        _bad('Sequences header is cut short.');
      }
      count = ((first - 128) << 8) + block[cursor++];
    } else {
      if (cursor + 2 > end) {
        _bad('Sequences header is cut short.');
      }
      count = block[cursor] + (block[cursor + 1] << 8) + 0x7F00;
      cursor += 2;
    }
    if (count == 0) {
      if (cursor != end) {
        _bad('Data after an empty sequences section.');
      }
      _reserve(literals.length);
      _out.setRange(_length, _length + literals.length, literals);
      _length += literals.length;
      return;
    }
    if (cursor >= end) {
      _bad('Sequences header is cut short.');
    }
    final modes = block[cursor++];
    if (modes & 3 != 0) {
      _bad('Reserved sequence mode bits are set.');
    }
    void moved(int next) => cursor = next;
    final ll = _ll = _table(
      modes >> 6,
      block,
      end,
      _llDefault,
      _ll,
      9,
      36,
      moved,
      cursor,
    );
    final of = _of = _table(
      (modes >> 4) & 3,
      block,
      end,
      _ofDefault,
      _of,
      8,
      32,
      moved,
      cursor,
    );
    final ml = _ml = _table(
      (modes >> 2) & 3,
      block,
      end,
      _mlDefault,
      _ml,
      9,
      53,
      moved,
      cursor,
    );

    final reader = _BackwardBits(Uint8List.sublistView(block, cursor, end));
    var llState = reader.read(ll.accuracy);
    var ofState = reader.read(of.accuracy);
    var mlState = reader.read(ml.accuracy);
    var literal = 0;
    for (var i = 0; i < count; i++) {
      final ofCode = of.symbols[ofState];
      final mlCode = ml.symbols[mlState];
      final llCode = ll.symbols[llState];
      if (ofCode > 31 || mlCode >= _mlBase.length || llCode >= _llBase.length) {
        _bad('Sequence code is out of range.');
      }
      final offsetValue = (1 << ofCode) + reader.read(ofCode);
      final matchLength = _mlBase[mlCode] + reader.read(_mlExtra[mlCode]);
      final literalLength = _llBase[llCode] + reader.read(_llExtra[llCode]);
      if (i != count - 1) {
        llState = ll.base[llState] + reader.read(ll.bits[llState]);
        mlState = ml.base[mlState] + reader.read(ml.bits[mlState]);
        ofState = of.base[ofState] + reader.read(of.bits[ofState]);
      }
      if (literal + literalLength > literals.length) {
        _bad('Sequence reads past the literals.');
      }
      _reserve(literalLength + matchLength);
      _out.setRange(_length, _length + literalLength, literals, literal);
      _length += literalLength;
      literal += literalLength;
      final distance = _distance(offsetValue, literalLength);
      if (distance <= 0 || distance > _length) {
        _bad('Match reaches before the start of the frame.');
      }
      if (distance >= matchLength) {
        _out.setRange(_length, _length + matchLength, _out, _length - distance);
        _length += matchLength;
      } else {
        // The match overlaps what it writes, so it repeats: byte by byte.
        for (var j = 0; j < matchLength; j++) {
          _out[_length] = _out[_length - distance];
          _length++;
        }
      }
    }
    if (reader.offset != 0) {
      _bad('Sequences bitstream has the wrong length.');
    }
    final rest = literals.length - literal;
    _reserve(rest);
    _out.setRange(_length, _length + rest, literals, literal);
    _length += rest;
  }

  /// RFC 8878 §3.1.1.5: values 1 to 3 name a recent offset, and the meaning
  /// shifts by one when the sequence has no literals.
  int _distance(int value, int literalLength) {
    if (value > 3) {
      final distance = value - 3;
      _repeat[2] = _repeat[1];
      _repeat[1] = _repeat[0];
      _repeat[0] = distance;
      return distance;
    }
    final index = value - 1 + (literalLength == 0 ? 1 : 0);
    final distance = index < 3 ? _repeat[index] : _repeat[0] - 1;
    if (index > 1) {
      _repeat[2] = _repeat[1];
    }
    if (index > 0) {
      _repeat[1] = _repeat[0];
      _repeat[0] = distance;
    }
    return distance;
  }
}

const int _p1 = 0x9E3779B185EBCA87;
const int _p2 = 0xC2B2AE3D27D4EB4F;
const int _p3 = 0x165667B19E3779F9;
const int _p4 = 0x85EBCA77C2B2AE63;
const int _p5 = 0x27D4EB2F165667C5;

int _rotl(int value, int bits) => (value << bits) | (value >>> (64 - bits));

int _round(int accumulator, int input) =>
    _rotl(accumulator + input * _p2, 31) * _p1;

int _merge(int hash, int value) => (hash ^ _round(0, value)) * _p1 + _p4;

/// XXH64 with seed 0, which frames use for their checksum. Relies on the
/// 64-bit wrapping integers of the VM and of AOT.
int xxh64(Uint8List data) {
  final view = ByteData.sublistView(data);
  final length = data.length;
  var position = 0;
  var hash = 0;
  if (length >= 32) {
    var v1 = _p1 + _p2;
    var v2 = _p2;
    var v3 = 0;
    var v4 = -_p1;
    while (position <= length - 32) {
      v1 = _round(v1, view.getInt64(position, Endian.little));
      v2 = _round(v2, view.getInt64(position + 8, Endian.little));
      v3 = _round(v3, view.getInt64(position + 16, Endian.little));
      v4 = _round(v4, view.getInt64(position + 24, Endian.little));
      position += 32;
    }
    hash = _rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18);
    hash = _merge(_merge(_merge(_merge(hash, v1), v2), v3), v4);
  } else {
    hash = _p5;
  }
  hash += length;
  while (position + 8 <= length) {
    hash ^= _round(0, view.getInt64(position, Endian.little));
    hash = _rotl(hash, 27) * _p1 + _p4;
    position += 8;
  }
  if (position + 4 <= length) {
    hash ^= view.getUint32(position, Endian.little) * _p1;
    hash = _rotl(hash, 23) * _p2 + _p3;
    position += 4;
  }
  while (position < length) {
    hash ^= data[position] * _p5;
    hash = _rotl(hash, 11) * _p1;
    position++;
  }
  hash ^= hash >>> 33;
  hash *= _p2;
  hash ^= hash >>> 29;
  hash *= _p3;
  return hash ^ (hash >>> 32);
}
