import 'dart:convert';
import 'dart:typed_data';

/// An error reply (`-ERR ...`, RESP3 `!`): the command reached the server
/// and was refused.
final class RedisCommandException implements Exception {
  const RedisCommandException(this.message);

  /// The server's message, starting with its code (`ERR`, `NOSCRIPT`,
  /// `WRONGTYPE`, ...).
  final String message;

  /// The first word of [message].
  String get code {
    final space = message.indexOf(' ');
    return space < 0 ? message : message.substring(0, space);
  }

  @override
  String toString() => 'RedisCommandException: $message';
}

/// The connection failed, closed, or a command timed out: whether the
/// command ran is unknown.
final class RedisConnectionException implements Exception {
  const RedisConnectionException(this.message);

  final String message;

  @override
  String toString() => 'RedisConnectionException: $message';
}

/// Too many commands are waiting for replies on one connection
/// (`REDIS_MAX_IN_FLIGHT`): refused at once instead of queueing without
/// bound.
final class RedisOverloadedException extends RedisConnectionException {
  const RedisOverloadedException(super.message);
}

/// A RESP3 push (`>`): a Pub/Sub message or an invalidation.
final class RespPush {
  const RespPush(this.items);

  final List<Object?> items;
}

/// The server's reply to a refused command, as a value of a pipeline.
final class RespError {
  const RespError(this.message);

  final String message;
}

/// Encodes one command as a RESP array of bulk strings. [args] are strings,
/// numbers or raw bytes (`List<int>`).
Uint8List encodeCommand(List<Object?> args) {
  final out = BytesBuilder(copy: false)
    ..add(ascii.encode('*${args.length}\r\n'));
  for (final arg in args) {
    final bytes = arg is List<int> ? arg : utf8.encode('${arg ?? ''}');
    out
      ..add(ascii.encode('\$${bytes.length}\r\n'))
      ..add(bytes)
      ..add(_crlf);
  }
  return out.takeBytes();
}

const List<int> _crlf = [13, 10];

/// A streaming RESP2 and RESP3 decoder: [add] chunks as they arrive, and
/// each complete value goes to [onValue] (an error reply as [RespError],
/// a push as [RespPush]). Bulk strings decode as UTF-8.
///
/// It refuses what no well-behaved server sends: bulk strings over
/// [maxBulkBytes], aggregates over [maxElements] or nested deeper than
/// [maxDepth], so a broken or hostile server cannot exhaust memory.
final class RespDecoder {
  RespDecoder(
    this.onValue, {
    this.maxBulkBytes = 512 * 1024 * 1024,
    this.maxElements = 10000000,
    this.maxDepth = 32,
  });

  final void Function(Object? value) onValue;
  final int maxBulkBytes;
  final int maxElements;
  final int maxDepth;

  Uint8List _buffer = Uint8List(0);
  int _length = 0;
  int _offset = 0;

  /// Appends [chunk] and emits every value it completes. Throws
  /// [FormatException] on a malformed stream (the connection must close).
  void add(List<int> chunk) {
    _append(chunk);
    while (_offset < _length) {
      final start = _offset;
      final Object? value;
      try {
        value = _value(0);
      } on _Incomplete {
        _offset = start;
        break;
      }
      onValue(value);
    }
    _compact();
  }

  void _append(List<int> chunk) {
    if (_length + chunk.length > _buffer.length) {
      final grown = Uint8List(
        (_length + chunk.length) * 2 < 4096
            ? 4096
            : (_length + chunk.length) * 2,
      )..setRange(0, _length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  void _compact() {
    if (_offset == 0) {
      return;
    }
    if (_offset == _length) {
      _offset = 0;
      _length = 0;
      if (_buffer.length > 1 << 20) {
        _buffer = Uint8List(4096);
      }
      return;
    }
    _buffer.setRange(0, _length - _offset, _buffer, _offset);
    _length -= _offset;
    _offset = 0;
  }

  /// The line from [_offset] to CRLF, without it.
  String _line() {
    for (var i = _offset; i + 1 < _length; i++) {
      if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
        final line = utf8.decode(
          Uint8List.sublistView(_buffer, _offset, i),
          allowMalformed: true,
        );
        _offset = i + 2;
        return line;
      }
    }
    throw const _Incomplete();
  }

  int _int(String text) =>
      int.tryParse(text) ??
      (throw FormatException('Invalid RESP integer [$text].'));

  int _count(String text) {
    final count = _int(text);
    if (count > maxElements) {
      throw FormatException('RESP aggregate of $count elements refused.');
    }
    return count;
  }

  String? _bulk(String header) {
    final size = _int(header);
    if (size < 0) {
      return null;
    }
    if (size > maxBulkBytes) {
      throw FormatException('RESP bulk string of $size bytes refused.');
    }
    if (_length - _offset < size + 2) {
      throw const _Incomplete();
    }
    final text = utf8.decode(
      Uint8List.sublistView(_buffer, _offset, _offset + size),
      allowMalformed: true,
    );
    _offset += size + 2;
    return text;
  }

  List<Object?> _items(int count, int depth) => [
    for (var i = 0; i < count; i++) _value(depth + 1),
  ];

  Object? _value(int depth) {
    if (depth > maxDepth) {
      throw const FormatException('RESP value nested too deeply.');
    }
    if (_offset >= _length) {
      throw const _Incomplete();
    }
    final type = _buffer[_offset++];
    final line = _line();
    switch (type) {
      case 0x2B: // + simple string
        return line;
      case 0x2D: // - error
        return RespError(line);
      case 0x3A: // : integer
        return _int(line);
      case 0x24: // $ bulk string
        return _bulk(line);
      case 0x2A: // * array
        final count = _int(line);
        return count < 0 ? null : _items(_count(line), depth);
      case 0x5F: // _ null
        return null;
      case 0x2C: // , double
        return double.tryParse(line.replaceAll('inf', 'Infinity')) ??
            double.nan;
      case 0x23: // # boolean
        return line == 't';
      case 0x21: // ! bulk error
        return RespError(_bulk(line) ?? '');
      case 0x3D: // = verbatim string: "txt:" then the text
        final text = _bulk(line) ?? '';
        return text.length >= 4 ? text.substring(4) : text;
      case 0x28: // ( big number
        return BigInt.tryParse(line) ?? line;
      case 0x25: // % map
        final count = _count(line);
        final map = <Object?, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = _value(depth + 1);
          map[key] = _value(depth + 1);
        }
        return map;
      case 0x7E: // ~ set
        return _items(_count(line), depth);
      case 0x3E: // > push
        return RespPush(_items(_count(line), depth));
      case 0x7C: // | attribute: metadata about the next value
        final count = _count(line);
        for (var i = 0; i < count * 2; i++) {
          _value(depth + 1);
        }
        return _value(depth);
    }
    throw FormatException('Unknown RESP type [${String.fromCharCode(type)}].');
  }
}

final class _Incomplete implements Exception {
  const _Incomplete();
}
