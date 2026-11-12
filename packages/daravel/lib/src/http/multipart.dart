import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException, IOException;
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mime/mime.dart';

import 'http_exceptions.dart';
import 'request.dart';
import 'uploaded_file.dart';

/// Fields and files of a `multipart/form-data` body.
final class MultipartBody {
  /// The parsed [fields] and [files] of a body.
  const MultipartBody(this.fields, this.files);

  /// Fields and files nested like PHP's `$_POST` + `$_FILES`: `photos[]`
  /// becomes a list of [UploadedFile], `user[name]` a map.
  final Map<String, Object?> fields;

  /// Every uploaded file, for clean-up.
  final List<UploadedFile> files;
}

/// Limits applied while parsing (PHP's `max_input_vars`,
/// `max_file_uploads`; the total size is the request's body limit).
final class MultipartLimits {
  /// Limits on a multipart body.
  const MultipartLimits({
    this.maxParts = 1000,
    this.maxFiles = 20,
    this.maxFieldBytes = 1 << 20,
    this.maxPartHeaderBytes = 16 * 1024,
    this.maxPartHeaders = 100,
  });

  /// The most parts a body may have; beyond it the body is refused with
  /// 400. PHP's default is 1 020 (`max_multipart_body_parts` -1 is
  /// `max_input_vars` 1 000 + `max_file_uploads` 20), and PHP stops
  /// reading there and keeps the parts read so far; refusing instead never
  /// validates a form cut short.
  final int maxParts;

  /// The most files a body may have.
  final int maxFiles;

  /// The largest field value, in bytes.
  final int maxFieldBytes;

  /// The most bytes of one part's header block, from its delimiter line to
  /// the blank line after its headers: 16 KiB, as busboy (Node's multipart
  /// parser). PHP's parser sets no limit. Beyond it the body is refused
  /// with 400 before the headers are buffered.
  final int maxPartHeaderBytes;

  /// The most header lines of one part (100, as Apache's request header
  /// default); refused like [maxPartHeaderBytes].
  final int maxPartHeaders;
}

/// The boundary of a `multipart/form-data` content type, or `null`.
String? multipartBoundary(String? contentType) {
  if (contentType == null) {
    return null;
  }
  final type = contentType.toLowerCase();
  if (!type.startsWith('multipart/form-data')) {
    return null;
  }
  final match = RegExp(
    r'boundary=(?:"([^"]+)"|([^;\s]+))',
    caseSensitive: false,
  ).firstMatch(contentType);
  return match?.group(1) ?? match?.group(2);
}

/// Parses [body] (already limited to the request's maximum size by the
/// caller). Files are written to [tempDirectory]; on any error the files
/// written so far, and the one being written, are deleted.
///
/// A body that ends or fails before its closing boundary, even inside a
/// part, completes with [BadRequestHttpException] (the body limit's
/// [PayloadTooLargeHttpException] stays one).
Future<MultipartBody> parseMultipart(
  Stream<List<int>> body,
  String boundary, {
  MultipartLimits limits = const MultipartLimits(),
  Directory? tempDirectory,
}) {
  final result = Completer<MultipartBody>();
  final files = <UploadedFile>[];
  _Parts? parts;
  // package:mime throws some parse errors synchronously inside its stream
  // listener, where they escape as uncaught zone errors instead of stream
  // errors; the guarded zone turns them into a 400 instead of a hang.
  runZonedGuarded(
    () async {
      try {
        final reader = parts = _Parts(
          // `bind` (not `transform`) also accepts a `Stream<Uint8List>`.
          MimeMultipartTransformer(boundary)
              .bind(limitPartHeaders(body, boundary, limits)),
        );
        result.complete(await _parse(reader, limits, tempDirectory, files));
      } catch (error, stack) {
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      }
    },
    (error, stack) {
      final reader = parts;
      if (reader != null) {
        // The parse stops at the part it reads and cleans up.
        reader.fail(error, stack);
        return;
      }
      if (result.isCompleted) {
        return;
      }
      unawaited(_deleteAll(files));
      result.completeError(_bodyError(error), stack);
    },
  );
  return result.future;
}

/// [body] unchanged, failing with [BadRequestHttpException] as soon as a
/// part's header block (from its delimiter line to the blank line ending
/// its headers) holds more than [MultipartLimits.maxPartHeaderBytes] bytes
/// or [MultipartLimits.maxPartHeaders] header lines.
///
/// `package:mime` buffers a part's headers without a limit, up to the
/// body limit (50 MiB by default); this bounds them before it reads them.
/// The bytes are scanned once, in time linear in the body: the delimiter
/// is found with Knuth–Morris–Pratt, so a delimiter split across chunks is
/// found as one that is not.
///
/// Only a delimiter after CRLF is recognised, as RFC 2046 writes it. A
/// body that puts one elsewhere (right after a part's blank line, with no
/// CRLF before it) escapes the limits for the parts after it, and is
/// parsed by `package:mime` as before: the limits fail open there, the
/// parsing does not change. A body that ends or fails inside a part,
/// which leaves `package:mime`'s part pending, is failed by [_Parts]
/// (`multipart_test.dart` and `multipart_socket_test.dart`, #145).
@visibleForTesting
Stream<List<int>> limitPartHeaders(
  Stream<List<int>> body,
  String boundary,
  MultipartLimits limits,
) async* {
  final scanner = PartHeaderScanner(
    boundary,
    maxBytes: limits.maxPartHeaderBytes,
    maxHeaders: limits.maxPartHeaders,
  );
  await for (final chunk in body) {
    scanner.add(chunk);
    yield chunk;
  }
}

/// Follows a multipart body byte by byte and throws
/// [BadRequestHttpException] when a part's header block is too large; see
/// [limitPartHeaders].
@visibleForTesting
final class PartHeaderScanner {
  /// A scanner for the body delimited by [boundary].
  PartHeaderScanner(
    String boundary, {
    required this.maxBytes,
    required this.maxHeaders,
  }) : _delimiter = latin1.encode('\r\n--$boundary') {
    _failure = List<int>.filled(_delimiter.length, 0);
    for (var i = 1, k = 0; i < _delimiter.length; i++) {
      while (k > 0 && _delimiter[i] != _delimiter[k]) {
        k = _failure[k - 1];
      }
      if (_delimiter[i] == _delimiter[k]) {
        k++;
      }
      _failure[i] = k;
    }
  }

  /// The most bytes of one part's header block.
  final int maxBytes;

  /// The most header lines of one part.
  final int maxHeaders;

  final Uint8List _delimiter;
  late final List<int> _failure;

  // The body starts with `--boundary`, without the CRLF before it: the
  // match starts as if that CRLF had been read.
  int _matched = 2;
  _ScanState _state = _ScanState.data;
  int _headerBytes = 0;
  int _headers = 0;
  int _lineBytes = 0;
  int _dashes = 0;

  /// Reads [chunk]; throws when a header block goes past a limit.
  void add(List<int> chunk) {
    final n = chunk.length;
    var i = 0;
    while (i < n) {
      if (_state == _ScanState.data && _matched == 0) {
        // Nothing matched: a delimiter can only start at a CR. Skipping
        // to it in a tight loop keeps the content's bytes cheap; each
        // byte is still read once.
        while (i < n && chunk[i] != 0x0d) {
          i++;
        }
        if (i == n) {
          return;
        }
      }
      final byte = chunk[i++];
      switch (_state) {
        case _ScanState.data:
          while (_matched > 0 && byte != _delimiter[_matched]) {
            _matched = _failure[_matched - 1];
          }
          if (byte == _delimiter[_matched]) {
            _matched++;
          }
          if (_matched == _delimiter.length) {
            _matched = 0;
            _state = _ScanState.delimiterLine;
            _headerBytes = 0;
            _headers = 0;
            _dashes = 0;
          }
        case _ScanState.delimiterLine:
          _count();
          if (_dashes >= 0 && byte == 0x2d) {
            // `--` right after the boundary closes the body.
            if (++_dashes == 2) {
              _state = _ScanState.epilogue;
            }
          } else {
            _dashes = -1;
            if (byte == 0x0a) {
              _state = _ScanState.headers;
              _lineBytes = 0;
            }
          }
        case _ScanState.headers:
          _count();
          if (byte == 0x0a) {
            if (_lineBytes == 0) {
              // The blank line: the part's content starts.
              _state = _ScanState.data;
              _matched = 0;
            } else if (++_headers > maxHeaders) {
              throw BadRequestHttpException(
                'Malformed multipart body: a part has more than $maxHeaders '
                'headers.',
              );
            }
            _lineBytes = 0;
          } else if (byte != 0x0d) {
            _lineBytes++;
          }
        case _ScanState.epilogue:
          // What follows the closing delimiter is ignored, as by
          // package:mime.
          return;
      }
    }
  }

  void _count() {
    if (++_headerBytes > maxBytes) {
      throw BadRequestHttpException(
        'Malformed multipart body: a part header holds more than $maxBytes '
        'bytes.',
      );
    }
  }
}

enum _ScanState { data, delimiterLine, headers, epilogue }

/// A failure of the body or of its parsing as the client is told it.
Object _bodyError(Object error) => switch (error) {
  MimeMultipartException(:final message) => BadRequestHttpException(
    'Malformed multipart body: $message',
  ),
  // The connection dropped or failed while the body arrived.
  IOException() => const BadRequestHttpException(
    'Unexpected end of multipart body.',
  ),
  _ => error,
};

/// The parts of a multipart body, read one after the other.
///
/// `package:mime` reports the end or the failure of the body only on the
/// stream of parts, never on the part being read: a body cut off inside a
/// part left that part, and the parse waiting for it, pending for ever
/// (#145). The stream of parts is therefore listened to while a part is
/// read, so such an error fails that part at once. Between parts it is
/// paused, which pauses the body as `await for` did.
final class _Parts {
  _Parts(Stream<MimeMultipart> parts) {
    _subscription = parts.listen(_add, onError: fail, onDone: _end);
  }

  late final StreamSubscription<MimeMultipart> _subscription;
  final List<MimeMultipart> _ready = <MimeMultipart>[];
  bool _ended = false;
  bool _paused = false;
  Object? _error;
  StackTrace? _errorStack;
  Completer<void>? _changed;
  void Function()? _abortRead;

  void _add(MimeMultipart part) {
    _ready.add(part);
    _wake();
  }

  void _end() {
    _ended = true;
    _wake();
  }

  /// Fails the parse with [error]: the part being read at once, the next
  /// call otherwise. The first error wins.
  void fail(Object error, StackTrace stack) {
    if (_error != null) {
      return;
    }
    _error = _bodyError(error);
    _errorStack = stack;
    _wake();
    _abortRead?.call();
  }

  void _wake() {
    final changed = _changed;
    _changed = null;
    changed?.complete();
  }

  void _pause() {
    if (!_paused) {
      _paused = true;
      _subscription.pause();
    }
  }

  void _resume() {
    if (_paused) {
      _paused = false;
      _subscription.resume();
    }
  }

  /// The next part, or `null` after the last one.
  Future<MimeMultipart?> next() async {
    _resume();
    while (true) {
      final error = _error;
      if (error != null) {
        Error.throwWithStackTrace(error, _errorStack!);
      }
      if (_ready.isNotEmpty) {
        return _ready.removeAt(0);
      }
      if (_ended) {
        return null;
      }
      await (_changed ??= Completer<void>()).future;
    }
  }

  /// Passes every chunk of [part] to [onChunk] until the part ends; fails
  /// with what [onChunk] throws or with the body's failure.
  Future<void> read(MimeMultipart part, void Function(List<int>) onChunk) {
    final done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    void finish([Object? error, StackTrace? stack]) {
      if (done.isCompleted) {
        return;
      }
      _abortRead = null;
      // Synchronously, while package:mime closes the part: it then pauses
      // the body until the next part is asked for.
      _pause();
      if (error == null) {
        done.complete();
      } else {
        unawaited(subscription.cancel());
        done.completeError(error, stack);
      }
    }

    subscription = part.listen(
      (chunk) {
        try {
          onChunk(chunk);
        } catch (error, stack) {
          finish(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) =>
          finish(_bodyError(error), stack),
      onDone: finish,
    );
    _abortRead = () => finish(_error, _errorStack);
    _resume();
    if (_error != null) {
      finish(_error, _errorStack);
    }
    return done.future;
  }

  /// Stops reading the body.
  void cancel() {
    _abortRead = null;
    unawaited(_subscription.cancel());
  }
}

void _ignore(List<int> chunk) {}

Future<MultipartBody> _parse(
  _Parts parts,
  MultipartLimits limits,
  Directory? tempDirectory,
  List<UploadedFile> files,
) async {
  final directory = tempDirectory ?? _defaultTempDirectory();
  final pairs = <(String, Object)>[];
  var count = 0;
  try {
    while (true) {
      final part = await parts.next();
      if (part == null) {
        break;
      }
      if (++count > limits.maxParts) {
        throw const BadRequestHttpException('Too many form fields.');
      }
      final disposition = _parseDisposition(
        part.headers['content-disposition'],
      );
      final name = disposition['name'];
      if (name == null || name.isEmpty) {
        await parts.read(part, _ignore);
        continue;
      }
      final filename = disposition['filename*'] ?? disposition['filename'];
      if (filename == null) {
        pairs.add((name, await _readField(parts, part, limits.maxFieldBytes)));
        continue;
      }
      if (filename.isEmpty) {
        // A file input left empty (PHP's UPLOAD_ERR_NO_FILE): no value.
        await parts.read(part, _ignore);
        continue;
      }
      if (files.length >= limits.maxFiles) {
        throw const BadRequestHttpException('Too many uploaded files.');
      }
      final file = await _writeFile(
        parts,
        part,
        directory,
        clientName: _baseName(filename),
        clientMimeType:
            part.headers['content-type'] ?? 'application/octet-stream',
      );
      files.add(file);
      pairs.add((name, file));
    }
  } catch (_) {
    parts.cancel();
    await _deleteAll(files);
    rethrow;
  }
  return MultipartBody(buildInput(pairs), files);
}

Directory _defaultTempDirectory() =>
    Directory('${Directory.systemTemp.path}/daravel-uploads')
      ..createSync(recursive: true);

Future<String> _readField(_Parts parts, MimeMultipart part, int limit) async {
  final builder = BytesBuilder(copy: false);
  await parts.read(part, (chunk) {
    builder.add(chunk);
    if (builder.length > limit) {
      throw const PayloadTooLargeHttpException();
    }
  });
  return utf8.decode(builder.takeBytes(), allowMalformed: true);
}

/// Streams [part] to a temporary file; the file is deleted when the part
/// or the write fails.
Future<UploadedFile> _writeFile(
  _Parts parts,
  MimeMultipart part,
  Directory directory, {
  required String clientName,
  required String clientMimeType,
}) async {
  final path = '${directory.path}/${_tempName()}';
  final sink = File(path).openWrite();
  final header = BytesBuilder();
  var size = 0;
  Object? failure;
  StackTrace? failureStack;
  try {
    await parts.read(part, (chunk) {
      sink.add(chunk);
      size += chunk.length;
      if (header.length < UploadedFile.headerLength) {
        final room = UploadedFile.headerLength - header.length;
        header.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
      }
    });
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  }
  try {
    await sink.close();
  } catch (error, stack) {
    failure ??= error;
    failureStack ??= stack;
  }
  if (failure != null) {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Never created, or already gone.
    }
    Error.throwWithStackTrace(failure, failureStack!);
  }
  return UploadedFile.temporary(
    path: path,
    clientName: clientName,
    clientMimeType: clientMimeType.split(';').first.trim(),
    size: size,
    header: header.takeBytes(),
  );
}

Future<void> _deleteAll(List<UploadedFile> files) async {
  for (final file in files) {
    await file.delete();
  }
}

/// `form-data; name="a"; filename="b.png"` → `{name: a, filename: b.png}`,
/// including RFC 5987 `filename*=UTF-8''...`.
Map<String, String> _parseDisposition(String? header) {
  final result = <String, String>{};
  if (header == null) {
    return result;
  }
  for (final (rawKey, rawValue) in dispositionParameters(header)) {
    final key = rawKey.toLowerCase();
    var value = rawValue;
    if (key == 'filename*') {
      final quote = value.indexOf("''");
      if (quote != -1) {
        try {
          value = Uri.decodeComponent(value.substring(quote + 2));
        } on ArgumentError {
          continue;
        }
      }
    }
    result[key] = value;
  }
  return result;
}

/// The `key=value` parameters of a `Content-Disposition` header, values
/// unquoted and unescaped: what the regular expression
/// `([A-Za-z*]+)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^;]*))` found, in one pass.
/// That expression retried every position of a long run of letters without
/// `=` (a client's part header), quadratic: 64 000 letters took 79 s. A
/// quoted value without its closing quote is taken unquoted, as the
/// expression's second branch did.
@visibleForTesting
Iterable<(String, String)> dispositionParameters(String header) sync* {
  bool isKey(int c) =>
      (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x2a;
  bool isSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0d);
  bool isLineEnd(int c) => c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029;
  final n = header.length;
  var i = 0;
  while (i < n) {
    if (!isKey(header.codeUnitAt(i))) {
      i++;
      continue;
    }
    final keyStart = i;
    while (i < n && isKey(header.codeUnitAt(i))) {
      i++;
    }
    final key = header.substring(keyStart, i);
    var j = i;
    while (j < n && isSpace(header.codeUnitAt(j))) {
      j++;
    }
    if (j >= n || header.codeUnitAt(j) != 0x3d) {
      // No `=` after this key: a match cannot start inside it either, as
      // the same text follows; go on after it.
      continue;
    }
    j++;
    while (j < n && isSpace(header.codeUnitAt(j))) {
      j++;
    }
    if (j < n && header.codeUnitAt(j) == 0x22) {
      final value = StringBuffer();
      var k = j + 1;
      var closed = false;
      while (k < n) {
        final c = header.codeUnitAt(k);
        if (c == 0x22) {
          closed = true;
          k++;
          break;
        }
        if (c == 0x5c) {
          if (k + 1 >= n || isLineEnd(header.codeUnitAt(k + 1))) {
            break;
          }
          value.writeCharCode(header.codeUnitAt(k + 1));
          k += 2;
          continue;
        }
        value.writeCharCode(c);
        k++;
      }
      if (closed) {
        yield (key, value.toString());
        i = k;
        continue;
      }
    }
    var k = j;
    while (k < n && header.codeUnitAt(k) != 0x3b) {
      k++;
    }
    yield (key, header.substring(j, k).trim());
    i = k;
  }
}

/// The last path segment of a client file name (browsers on Windows may
/// send `C:\fakepath\name.png`).
String _baseName(String name) {
  final segments = name.split(RegExp(r'[\\/]'));
  return segments.last;
}

final Random _random = Random.secure();

String _tempName() =>
    'upload-${DateTime.now().microsecondsSinceEpoch}-'
    '${_random.nextInt(1 << 32).toRadixString(16)}';
