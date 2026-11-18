import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';

import '../storage/storage.dart';
import 'headers.dart';
import 'http_exceptions.dart';
import 'request.dart';
import 'response.dart';

/// `Content-Disposition` by RFC 6266: an ASCII `filename` for old clients and
/// `filename*` (RFC 5987) when the name is not plain ASCII. A name with a
/// path or a control character is a programming error, as in Symfony's
/// `HeaderUtils::makeDisposition`.
String contentDisposition(String name, {bool inline = false}) {
  if (name.isEmpty || name.contains(RegExp(r'[/\\\x00-\x1f\x7f]'))) {
    throw ArgumentError.value(name, 'name', 'Not a file name.');
  }
  final kind = inline ? 'inline' : 'attachment';
  final fallback = name
      .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
      .replaceAll('%', '_')
      .replaceAllMapped(RegExp(r'["\\]'), (match) => '\\${match[0]}');
  final plain = RegExp(r'^[\x20-\x7e]*$').hasMatch(name) && !name.contains('%');
  if (plain) {
    return '$kind; filename="$fallback"';
  }
  return "$kind; filename=\"$fallback\"; filename*=UTF-8''${_extValue(name)}";
}

/// RFC 5987 `attr-char`, which leaves fewer characters bare than a URI.
String _extValue(String name) =>
    Uri.encodeComponent(name)
        .replaceAllMapped(RegExp(r"[!'()*]"), (m) => _percent(m[0]!));

String _percent(String char) =>
    '%${char.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(2, '0')}';

/// A byte range of a file of [size] bytes, end exclusive.
typedef _Range = ({int start, int end});

/// The `bytes=` range of [header], `null` to serve the whole file, or
/// [_unsatisfiable]. A list of ranges is served whole: answering it needs
/// `multipart/byteranges`, and RFC 9110 lets a server ignore `Range`.
Object? _parseRange(String? header, int size) {
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header?.trim() ?? '');
  if (match == null) {
    return null;
  }
  final first = match[1]!;
  final last = match[2]!;
  if (first.isEmpty && last.isEmpty) {
    return null;
  }
  // A number past the integers is past any file too.
  final from = int.tryParse(first);
  final to = int.tryParse(last);
  if ((first.isNotEmpty && from == null) || (last.isNotEmpty && to == null)) {
    return first.isNotEmpty && from == null ? _unsatisfiable : null;
  }
  if (from == null) {
    return to == 0 || size == 0
        ? _unsatisfiable
        : (start: to! >= size ? 0 : size - to, end: size);
  }
  if (from >= size || (to != null && to < from)) {
    return to != null && to < from ? null : _unsatisfiable;
  }
  return (start: from, end: to == null || to >= size ? size : to + 1);
}

const Object _unsatisfiable = Object();

/// Whether an `If-None-Match` [value] (its header lines joined with `, `,
/// as RFC 9110 §5.3 combines a field sent more than once) matches the
/// entity tag [etag], by the weak comparison RFC 9110 §13.1.2 asks for.
///
/// RFC 9110 §13.1.2: `If-None-Match = "*" / #entity-tag`, so `*` matches
/// only as the whole value. §8.8.3: `entity-tag = [ weak ] opaque-tag`,
/// `weak = %s"W/"` (case-sensitive), `opaque-tag = DQUOTE *etagc DQUOTE`,
/// `etagc = %x21 / %x23-7E / obs-text`: a comma or a `*` inside the quotes
/// is part of the tag. §5.6.1: the list's members are separated by commas
/// with optional whitespace, and empty members are skipped. §8.8.3.2:
/// weakly, two tags match when their opaque tags are the same, whether
/// either is weak. A value that does not read this way matches nothing.
bool matchesIfNoneMatch(String value, String etag) {
  if (_trimOws(value) == '*') {
    return true;
  }
  final tags = _entityTags(value);
  if (tags == null) {
    return false;
  }
  final current = etag.startsWith('W/') ? etag.substring(2) : etag;
  return tags.contains(current);
}

String _trimOws(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isOws(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isOws(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

bool _isOws(int unit) => unit == 0x20 || unit == 0x09;

/// The opaque tags (with their quotes, without `W/`) of a `#entity-tag`
/// list, or null when [value] is not one. One pass.
List<String>? _entityTags(String value) {
  final tags = <String>[];
  var i = 0;
  final length = value.length;
  while (true) {
    // Whitespace and empty members (commas) before the next tag.
    while (i < length) {
      final unit = value.codeUnitAt(i);
      if (!_isOws(unit) && unit != 0x2C) {
        break;
      }
      i++;
    }
    if (i == length) {
      return tags;
    }
    if (value.startsWith('W/', i)) {
      i += 2;
    }
    if (i == length || value.codeUnitAt(i) != 0x22) {
      return null;
    }
    final open = i;
    i++;
    while (i < length && value.codeUnitAt(i) != 0x22) {
      final unit = value.codeUnitAt(i);
      if (!(unit == 0x21 ||
          (unit >= 0x23 && unit <= 0x7E) ||
          (unit >= 0x80 && unit <= 0xFF))) {
        return null;
      }
      i++;
    }
    if (i == length) {
      return null; // Unterminated.
    }
    i++;
    tags.add(value.substring(open, i));
    while (i < length && _isOws(value.codeUnitAt(i))) {
      i++;
    }
    if (i < length && value.codeUnitAt(i) != 0x2C) {
      return null;
    }
  }
}

/// What every file response shares: `Last-Modified`, an `ETag`, conditional
/// requests and ranges. [open] gives the bytes from `start` up to `end`.
Response _serve({
  required int size,
  required DateTime modified,
  required Stream<List<int>> Function(int start, int end) open,
  required String contentType,
  String? disposition,
  Map<String, String>? headers,
  Request? request,
  bool ranges = true,
}) {
  final etag =
      '"${size.toRadixString(16)}-${modified.millisecondsSinceEpoch.toRadixString(16)}"';
  final lastModified = HttpDate.format(modified);
  final common = <String, Object>{
    'content-type': contentType,
    if (ranges) 'accept-ranges': 'bytes',
    'etag': etag,
    'last-modified': lastModified,
    // A browser must not turn an upload into a page by sniffing it.
    'x-content-type-options': 'nosniff',
    'content-disposition': ?disposition,
    ...?headers,
  };
  final readable = request?.method == 'GET' || request?.method == 'HEAD';
  // Every line of the field, joined (RFC 9110 §5.3).
  final ifNoneMatchLines = request?.headers.all('if-none-match') ?? const [];
  final ifNoneMatch = ifNoneMatchLines.isEmpty
      ? null
      : ifNoneMatchLines.join(', ');
  if (readable &&
      ifNoneMatch != null &&
      matchesIfNoneMatch(ifNoneMatch, etag)) {
    return Response(status: 304, headers: Headers(common));
  }
  final ifRange = request?.headers.first('if-range');
  final current = ifRange == null || ifRange == etag || ifRange == lastModified;
  final range = ranges && readable && current
      ? _parseRange(request!.headers.first('range'), size)
      : null;
  if (identical(range, _unsatisfiable)) {
    return Response(
      status: 416,
      headers: Headers({...common, 'content-range': 'bytes */$size'}),
    );
  }
  if (range is _Range) {
    final length = range.end - range.start;
    return Response(
      status: 206,
      headers: Headers({
        ...common,
        'content-range': 'bytes ${range.start}-${range.end - 1}/$size',
        'content-length': '$length',
      }),
      body: StreamBody(open(range.start, range.end), contentLength: length),
      contentLengthOverride: length,
    );
  }
  return Response(
    headers: Headers({...common, 'content-length': '$size'}),
    body: StreamBody(open(0, size), contentLength: size),
    contentLengthOverride: size,
  );
}

File _toFile(Object fileOrPath) => switch (fileOrPath) {
  final File file => file,
  final String path => File(path),
  _ => throw ArgumentError.value(fileOrPath, 'fileOrPath', 'A File or a path.'),
};

/// Types pinned here rather than left to `package:mime`, whose table has
/// changed between versions (`.js` was `application/javascript`) and lacks
/// source maps. Fonts, modules and wasm must be exact: under `nosniff` a
/// browser refuses a script or a wasm module served with another type.
const Map<String, String> _pinnedTypes = {
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'css': 'text/css',
  'map': 'application/json',
  'json': 'application/json',
  'wasm': 'application/wasm',
  'svg': 'image/svg+xml',
  'woff2': 'font/woff2',
  'woff': 'font/woff',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'webmanifest': 'application/manifest+json',
};

/// The `Content-Type` of a file called [name], by its extension.
String mimeTypeOf(String name) {
  final dot = name.lastIndexOf('.');
  final pinned = dot == -1
      ? null
      : _pinnedTypes[name.substring(dot + 1).toLowerCase()];
  return pinned ?? lookupMimeType(name) ?? 'application/octet-stream';
}

String _mimeOf(String name) => mimeTypeOf(name);

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

/// Sends the file at a path as the response, with range requests,
/// `ETag` and `Last-Modified`, streamed rather than read into memory.
Future<Response> sendFile(
  Object fileOrPath, {
  required bool inline,
  String? name,
  String? contentType,
  Map<String, String>? headers,
  Request? request,
  bool deleteAfterSend = false,
}) async {
  final file = _toFile(fileOrPath);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    throw const NotFoundHttpException();
  }
  final base = name ?? _baseName(file.path);
  return _serve(
    size: stat.size,
    modified: stat.modified,
    contentType: contentType ?? _mimeOf(base),
    disposition: contentDisposition(base, inline: inline),
    headers: headers,
    request: request,
    // A viewer probing with `Range: bytes=0-1023` would delete the file
    // before its real request.
    ranges: !deleteAfterSend,
    open: (start, end) => _read(file, start, end, deleteAfterSend),
  );
}

/// A public file without `Content-Disposition` (a stylesheet, a script, a
/// font), with the `ETag`, conditional requests and ranges of [sendFile].
/// [file] must come from the application, never from the request.
Future<Response> sendStaticFile(
  File file, {
  required String contentType,
  Map<String, String>? headers,
  Request? request,
}) async {
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    throw const NotFoundHttpException();
  }
  return _serve(
    size: stat.size,
    modified: stat.modified,
    contentType: contentType,
    headers: headers,
    request: request,
    open: file.openRead,
  );
}

/// Deletes once the stream ended or the client went away. A HEAD or a 304
/// never listens, so the file stays for the real download.
Stream<List<int>> _read(File file, int start, int end, bool delete) async* {
  try {
    yield* file.openRead(start, end);
  } finally {
    if (delete) {
      try {
        await file.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}

/// Bytes [start] up to [end] of a stream that cannot seek.
Stream<List<int>> _slice(Stream<List<int>> source, int start, int end) async* {
  var position = 0;
  await for (final chunk in source) {
    final from = position;
    position += chunk.length;
    if (position <= start) {
      continue;
    }
    final first = start > from ? start - from : 0;
    final last = end < position ? end - from : chunk.length;
    if (first < last) {
      yield first == 0 && last == chunk.length
          ? chunk
          : chunk.sublist(first, last);
    }
    if (position >= end) {
      return;
    }
  }
}

/// Laravel's `Storage::download()` and `Storage::response()`. These live on
/// the `http` side because `storage` depends on nothing but `foundation`.
extension DiskResponses on Disk {
  /// The file at [path] as an attachment.
  Future<Response> download(
    String path, {
    String? name,
    Map<String, String>? headers,
    Request? request,
  }) => _diskResponse(path, name, headers, request, inline: false);

  /// The file at [path], shown by the browser; with [request], ranges too.
  Future<Response> response(
    String path, {
    String? name,
    Map<String, String>? headers,
    Request? request,
  }) => _diskResponse(path, name, headers, request, inline: true);

  Future<Response> _diskResponse(
    String path,
    String? name,
    Map<String, String>? headers,
    Request? request, {
    required bool inline,
  }) async {
    if (await missing(path)) {
      throw const NotFoundHttpException();
    }
    final base = name ?? _baseName(path);
    return _serve(
      size: await size(path),
      modified: await lastModified(path),
      contentType: _mimeOf(base),
      disposition: contentDisposition(base, inline: inline),
      headers: headers,
      request: request,
      open: (start, end) => _slice(readStream(path), start, end),
    );
  }
}
