import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mime/mime.dart' as mime;
import 'package:path/path.dart' as p;

import '../foundation/container.dart';
import '../storage/storage.dart';

/// A file sent in a `multipart/form-data` request (Laravel's
/// `Illuminate\Http\UploadedFile`).
///
/// The upload is streamed to a temporary file while the request is parsed
/// (deleted once the response is sent); its first bytes are kept to detect
/// the real type. [clientName] and [clientMimeType] come from the client and
/// must not be trusted; [mimeType] and [extension] are read from the content,
/// as Laravel's `getMimeType()` and `guessExtension()` are.
final class UploadedFile {
  UploadedFile._({
    required this.clientName,
    required this.clientMimeType,
    required this.size,
    required this._header,
    this.path,
    this._bytes,
  });

  /// An upload held in memory (tests, generated files).
  factory UploadedFile.fromBytes(
    List<int> bytes, {
    required String name,
    String? mimeType,
  }) {
    final data = Uint8List.fromList(bytes);
    return UploadedFile._(
      clientName: name,
      clientMimeType: mimeType ?? 'application/octet-stream',
      size: data.length,
      header: Uint8List.sublistView(data, 0, min(data.length, headerLength)),
      bytes: data,
    );
  }

  /// An upload that was streamed to [path] (used by the multipart parser).
  factory UploadedFile.temporary({
    required String path,
    required String clientName,
    required String clientMimeType,
    required int size,
    required List<int> header,
  }) => UploadedFile._(
    clientName: clientName,
    clientMimeType: clientMimeType,
    size: size,
    header: Uint8List.fromList(header),
    path: path,
  );

  /// Fake uploads for tests (`UploadedFile::fake()`).
  static const UploadedFileFactory fake = UploadedFileFactory._();

  /// How many leading bytes are kept for type detection.
  static const int headerLength = 64 * 1024;

  /// The file name the client sent (`getClientOriginalName`).
  final String clientName;

  /// The MIME type the client claimed (`getClientMimeType`).
  final String clientMimeType;

  /// Size in bytes.
  final int size;

  /// Temporary file holding the content (`null` for in-memory uploads).
  final String? path;

  final Uint8List _header;
  final Uint8List? _bytes;
  String? _mimeType;

  /// The extension of [clientName], lower-cased, without the dot
  /// (`getClientOriginalExtension`).
  String get clientExtension =>
      p.extension(clientName).replaceFirst('.', '').toLowerCase();

  /// The type detected from the content (`getMimeType`), never from the
  /// name: `application/octet-stream` when it cannot be recognised.
  String get mimeType => _mimeType ??= detectMimeType(_header);

  /// The extension that matches [mimeType] (`guessExtension`), or `null`.
  String? get extension => extensionForMimeType(mimeType);

  /// The whole content.
  Future<Uint8List> bytes() async => _bytes ?? await File(path!).readAsBytes();

  /// The whole content, read synchronously (fakes and small files).
  Uint8List readAsBytesSync() => _bytes ?? File(path!).readAsBytesSync();

  /// The content as UTF-8 text (`getContent`).
  Future<String> text() async => utf8.decode(await bytes());

  /// The content as a stream.
  Stream<List<int>> openRead() {
    final bytes = _bytes;
    return bytes != null ? Stream.value(bytes) : File(path!).openRead();
  }

  /// A random 40-character name with the detected extension (`hashName`).
  String hashName([String? directory]) {
    final ext = extension ?? clientExtension;
    final name = '${_randomName()}${ext.isEmpty ? '' : '.$ext'}';
    return directory == null || directory.isEmpty
        ? name
        : _join(directory, name);
  }

  /// Stores the file under [directory] with a [hashName] on [disk] (the
  /// default disk when `null`) and returns its path (`store`).
  Future<String> store(String directory, {String? disk}) =>
      storeAs(directory, hashName(), disk: disk);

  /// Stores the file as [directory]/[name] on [disk] and returns the path
  /// (`storeAs`). [name] is not checked: never pass [clientName] unchanged.
  Future<String> storeAs(String directory, String name, {String? disk}) async {
    final target = _join(directory, name);
    final storage = Container.current.make<StorageManager>();
    await storage.disk(disk).putStream(target, openRead());
    return target;
  }

  /// Deletes the temporary file (done automatically after the response).
  Future<void> delete() async {
    final file = path == null ? null : File(path!);
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }

  @override
  String toString() => 'UploadedFile($clientName, $size bytes)';

  static String _join(String directory, String name) {
    final dir = directory.replaceAll(RegExp(r'^/+|/+$'), '');
    return dir.isEmpty ? name : '$dir/$name';
  }

  static final Random _random = Random.secure();
  static const String _alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  static String _randomName() => String.fromCharCodes([
    for (var i = 0; i < 40; i++)
      _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
  ]);
}

/// `UploadedFile.fake` helpers.
final class UploadedFileFactory {
  const UploadedFileFactory._();

  /// A file of [kilobytes] KB (zero bytes) named [name].
  UploadedFile create(String name, {int kilobytes = 0, String? mimeType}) =>
      UploadedFile.fromBytes(
        Uint8List(kilobytes * 1024),
        name: name,
        mimeType: mimeType,
      );

  /// A file with [content] (text is UTF-8).
  UploadedFile withContent(String name, Object content, {String? mimeType}) =>
      UploadedFile.fromBytes(
        content is String ? utf8.encode(content) : content as List<int>,
        name: name,
        mimeType: mimeType,
      );

  /// A valid 1x1 image: PNG, or GIF when [name] ends in `.gif`, padded to
  /// [kilobytes] KB when given.
  UploadedFile image(String name, {int kilobytes = 0}) {
    final gif = name.toLowerCase().endsWith('.gif');
    final base = gif ? _gif : _png;
    final bytes = Uint8List(max(base.length, kilobytes * 1024))
      ..setRange(0, base.length, base);
    return UploadedFile.fromBytes(
      bytes,
      name: name,
      mimeType: gif ? 'image/gif' : 'image/png',
    );
  }

  static final Uint8List _png = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
    '60e6kgAAAABJRU5ErkJggg==',
  );
  static final Uint8List _gif = base64.decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  );
}

/// Detects a MIME type from the first bytes of a file, never from its name:
/// `package:mime` signatures plus BMP, SVG, ZIP-based documents (Office Open
/// XML, OpenDocument) and plain text.
String detectMimeType(List<int> header) {
  if (header.isEmpty) {
    return 'application/x-empty';
  }
  bool startsWith(List<int> signature) =>
      header.length >= signature.length &&
      Iterable<int>.generate(signature.length)
          .every((i) => header[i] == signature[i]);

  if (startsWith(const [0x42, 0x4D]) && header.length > 14) {
    return 'image/bmp';
  }
  if (startsWith(const [0x50, 0x4B, 0x03, 0x04])) {
    return _zipDocumentType(header);
  }
  // An empty path disables the extension fallback.
  final known = mime.lookupMimeType('', headerBytes: header);
  if (known != null) {
    return known;
  }
  if (startsWith(const [0x1F, 0x8B])) {
    return 'application/gzip';
  }
  final text = _asText(header);
  if (text == null) {
    return 'application/octet-stream';
  }
  final start = text.trimLeft().toLowerCase();
  if (start.startsWith('<svg') ||
      (start.startsWith('<?xml') && start.contains('<svg'))) {
    return 'image/svg+xml';
  }
  if (start.startsWith('%pdf')) {
    return 'application/pdf';
  }
  if (start.startsWith('<!doctype html') || start.startsWith('<html')) {
    return 'text/html';
  }
  if (start.startsWith('<?xml')) {
    return 'text/xml';
  }
  if (start.startsWith('{') || start.startsWith('[')) {
    try {
      jsonDecode(text);
      return 'application/json';
    } on FormatException {
      // Not JSON (or truncated): plain text.
    }
  }
  return 'text/plain';
}

String _zipDocumentType(List<int> header) {
  final content = latin1.decode(header, allowInvalid: true);
  // OpenDocument stores its type uncompressed in the first entry.
  final odf = RegExp(r'mimetypeapplication/vnd\.oasis\.opendocument\.[a-z.]+')
      .firstMatch(content);
  if (odf != null) {
    return odf.group(0)!.substring('mimetype'.length);
  }
  if (content.contains('[Content_Types].xml') || content.contains('_rels/')) {
    if (content.contains('word/')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (content.contains('xl/')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (content.contains('ppt/')) {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
  }
  return 'application/zip';
}

String? _asText(List<int> header) {
  try {
    // A multi-byte character may be cut at the end of the header.
    final text = utf8.decode(header, allowMalformed: true);
    final controls = text.runes.where(
      (r) => r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D && r != 0x0C,
    );
    return controls.isEmpty && !text.contains('�') ? text : null;
  } on FormatException {
    return null;
  }
}

/// The usual extension for [mimeType] (Symfony's `guessExtension`).
String? extensionForMimeType(String mimeType) => switch (mimeType) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/bmp' => 'bmp',
  'image/webp' => 'webp',
  'image/svg+xml' => 'svg',
  'image/tiff' => 'tif',
  'image/heic' => 'heic',
  'application/pdf' => 'pdf',
  'application/zip' => 'zip',
  'application/gzip' => 'gz',
  'application/json' => 'json',
  'text/plain' => 'txt',
  'text/html' => 'html',
  'text/xml' => 'xml',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
    'docx',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
    'pptx',
  'application/vnd.oasis.opendocument.text' => 'odt',
  'application/vnd.oasis.opendocument.spreadsheet' => 'ods',
  'application/vnd.oasis.opendocument.presentation' => 'odp',
  'video/mp4' => 'mp4',
  'audio/mpeg' => 'mp3',
  _ => mime.extensionFromMime(mimeType),
};
