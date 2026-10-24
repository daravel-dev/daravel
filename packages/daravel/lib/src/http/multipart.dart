import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'http_exceptions.dart';
import 'request.dart';
import 'uploaded_file.dart';

/// Fields and files of a `multipart/form-data` body.
final class MultipartBody {
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
  const MultipartLimits({
    this.maxParts = 1000,
    this.maxFiles = 20,
    this.maxFieldBytes = 1 << 20,
  });

  final int maxParts;
  final int maxFiles;
  final int maxFieldBytes;
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
/// written so far are deleted.
Future<MultipartBody> parseMultipart(
  Stream<List<int>> body,
  String boundary, {
  MultipartLimits limits = const MultipartLimits(),
  Directory? tempDirectory,
}) {
  final result = Completer<MultipartBody>();
  final files = <UploadedFile>[];
  // package:mime throws some parse errors synchronously inside its stream
  // listener, where they escape as uncaught zone errors instead of stream
  // errors; the guarded zone turns them into a 400 instead of a hang.
  runZonedGuarded(
    () async {
      try {
        result.complete(
          await _parse(body, boundary, limits, tempDirectory, files),
        );
      } catch (error, stack) {
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      }
    },
    (error, stack) {
      if (result.isCompleted) {
        return;
      }
      unawaited(_deleteAll(files));
      result.completeError(
        error is MimeMultipartException
            ? BadRequestHttpException(
                'Malformed multipart body: ${error.message}',
              )
            : error,
        stack,
      );
    },
  );
  return result.future;
}

Future<MultipartBody> _parse(
  Stream<List<int>> body,
  String boundary,
  MultipartLimits limits,
  Directory? tempDirectory,
  List<UploadedFile> files,
) async {
  final directory = tempDirectory ?? _defaultTempDirectory();
  final pairs = <(String, Object)>[];
  var parts = 0;
  try {
    // `bind` (not `transform`) also accepts a `Stream<Uint8List>`.
    await for (final part in MimeMultipartTransformer(boundary).bind(body)) {
      if (++parts > limits.maxParts) {
        throw const BadRequestHttpException('Too many form fields.');
      }
      final disposition = _parseDisposition(
        part.headers['content-disposition'],
      );
      final name = disposition['name'];
      if (name == null || name.isEmpty) {
        await part.drain<void>();
        continue;
      }
      final filename = disposition['filename*'] ?? disposition['filename'];
      if (filename == null) {
        pairs.add((name, await _readField(part, limits.maxFieldBytes)));
        continue;
      }
      if (filename.isEmpty) {
        // A file input left empty (PHP's UPLOAD_ERR_NO_FILE): no value.
        await part.drain<void>();
        continue;
      }
      if (files.length >= limits.maxFiles) {
        throw const BadRequestHttpException('Too many uploaded files.');
      }
      final file = await _writeFile(
        part,
        directory,
        clientName: _baseName(filename),
        clientMimeType:
            part.headers['content-type'] ?? 'application/octet-stream',
      );
      files.add(file);
      pairs.add((name, file));
    }
  } on MimeMultipartException catch (error) {
    await _deleteAll(files);
    throw BadRequestHttpException('Malformed multipart body: ${error.message}');
  } catch (_) {
    await _deleteAll(files);
    rethrow;
  }
  return MultipartBody(buildInput(pairs), files);
}

Directory _defaultTempDirectory() =>
    Directory('${Directory.systemTemp.path}/daravel-uploads')
      ..createSync(recursive: true);

Future<String> _readField(MimeMultipart part, int limit) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in part) {
    builder.add(chunk);
    if (builder.length > limit) {
      throw const PayloadTooLargeHttpException();
    }
  }
  return utf8.decode(builder.takeBytes(), allowMalformed: true);
}

Future<UploadedFile> _writeFile(
  MimeMultipart part,
  Directory directory, {
  required String clientName,
  required String clientMimeType,
}) async {
  final path = '${directory.path}/${_tempName()}';
  final sink = File(path).openWrite();
  final header = BytesBuilder();
  var size = 0;
  try {
    await for (final chunk in part) {
      sink.add(chunk);
      size += chunk.length;
      if (header.length < UploadedFile.headerLength) {
        final room = UploadedFile.headerLength - header.length;
        header.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
      }
    }
  } finally {
    await sink.close();
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
  final pattern = RegExp(
    r'''([A-Za-z*]+)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^;]*))''',
  );
  for (final match in pattern.allMatches(header)) {
    final key = match.group(1)!.toLowerCase();
    var value =
        match
            .group(2)
            ?.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!) ??
        match.group(3)!.trim();
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
