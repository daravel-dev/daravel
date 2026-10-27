import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:mime/mime.dart';

import 'client.dart';
import 'config.dart';
import 'signer.dart';

/// A presigned request for a client to send itself, such as a browser or
/// Flutter app uploading straight to the bucket (Laravel's
/// `temporaryUploadUrl` array: `url` and `headers`).
final class S3PresignedRequest {
  const S3PresignedRequest(this.method, this.url, this.headers);

  final String method;
  final String url;

  /// Headers the request must carry unchanged: they are signed.
  final Map<String, String> headers;

  Map<String, Object?> toJson() => {
    'method': method,
    'url': url,
    'headers': headers,
  };
}

/// A presigned `POST` form (S3's POST policy) for a browser or app to
/// upload with: send [fields] as `multipart/form-data` to [url], with the
/// file as the last field, named `file`. Unlike a presigned `PUT` the
/// policy can bound the size and the content type.
final class S3PresignedPost {
  const S3PresignedPost(this.url, this.fields);

  final String url;

  /// Form fields to send unchanged, before `file`.
  final Map<String, String> fields;

  Map<String, Object?> toJson() => {
    'method': 'POST',
    'url': url,
    'fields': fields,
  };
}

/// A [Disk] on an S3 bucket or an S3-compatible store (Cloudflare R2,
/// MinIO, DigitalOcean Spaces, Google Cloud Storage's interoperability
/// API), with presigned download and upload URLs.
///
/// Directories are key prefixes; [makeDirectory] writes the empty `dir/`
/// marker object flysystem writes, so Laravel and Daravel see the same
/// tree.
final class S3Disk implements Disk {
  S3Disk(
    this.name,
    this.client, {
    String root = '',
    this.baseUrl,
    this.visibility = 'private',
    this.partSize = 8 * 1024 * 1024,
  }) : _prefix = _rootPrefix(root) {
    if (partSize < 1) {
      throw ArgumentError.value(partSize, 'partSize', 'Must be positive.');
    }
  }

  /// The disk of [config] (`AWS_*` in `.env`).
  factory S3Disk.fromConfig(
    String name,
    S3Config config, {
    HttpClient Function()? httpClient,
  }) => S3Disk(
    name,
    S3Client(
      signer: SigV4Signer(
        accessKey: config.accessKey,
        secretKey: config.secretKey,
        region: config.region,
        sessionToken: config.sessionToken,
      ),
      bucket: config.bucket,
      endpoint: config.endpoint,
      pathStyle: config.usePathStyleEndpoint,
      httpClient: httpClient,
    ),
    root: config.root,
    baseUrl: config.url,
    visibility: config.visibility,
  );

  @override
  final String name;
  final S3Client client;

  /// The public base URL of [url] (`AWS_URL`, a CDN); the bucket's own URL
  /// when `null`.
  final String? baseUrl;

  /// `public` writes objects with `x-amz-acl: public-read`.
  final String visibility;

  /// [putStream] uploads in parts of this size once a stream outgrows one
  /// (S3 requires at least 5 MiB for every part but the last).
  final int partSize;

  final String _prefix;

  static String _rootPrefix(String root) {
    final normalized = normalizeDiskPath(root);
    return normalized.isEmpty ? '' : '$normalized/';
  }

  /// The object key of a disk path.
  String key(String path) => '$_prefix${normalizeDiskPath(path)}';

  String _dirPrefix(String directory) {
    final dir = normalizeDiskPath(directory);
    return dir.isEmpty ? _prefix : '$_prefix$dir/';
  }

  String _relative(String key) => key.substring(_prefix.length);

  Map<String, String> _writeHeaders(String path) => {
    'content-type': lookupMimeType(path) ?? 'application/octet-stream',
    if (visibility == 'public') 'x-amz-acl': 'public-read',
  };

  StorageException _notFound(String path) =>
      StorageException('File not found at path: $path');

  /// Errors (an escaping path included) arrive through the future, as with
  /// the core disks.
  @override
  Future<void> put(String path, Object contents) async {
    await client.putObject(key(path), switch (contents) {
      String() => utf8.encode(contents),
      List<int>() => contents,
      _ => throw ArgumentError.value(
        contents,
        'contents',
        'Expected a String or List<int>.',
      ),
    }, headers: _writeHeaders(path));
  }

  /// Uploads [stream] holding at most [partSize] bytes in memory: one
  /// `PUT` when it fits in a part, a multipart upload (aborted on failure)
  /// when it does not.
  @override
  Future<void> putStream(String path, Stream<List<int>> stream) async {
    final objectKey = key(path);
    final headers = _writeHeaders(path);
    var buffer = BytesBuilder(copy: false);
    final etags = <String>[];
    String? uploadId;
    try {
      await for (final chunk in stream) {
        buffer.add(chunk);
        while (buffer.length >= partSize) {
          final bytes = buffer.takeBytes();
          buffer = BytesBuilder(copy: false)
            ..add(Uint8List.sublistView(bytes, partSize));
          uploadId ??= await client.createMultipartUpload(
            objectKey,
            headers: headers,
          );
          etags.add(
            await client.uploadPart(
              objectKey,
              uploadId,
              etags.length + 1,
              Uint8List.sublistView(bytes, 0, partSize),
            ),
          );
        }
      }
      final rest = buffer.takeBytes();
      if (uploadId == null) {
        await client.putObject(objectKey, rest, headers: headers);
        return;
      }
      if (rest.isNotEmpty) {
        etags.add(
          await client.uploadPart(objectKey, uploadId, etags.length + 1, rest),
        );
      }
      await client.completeMultipartUpload(objectKey, uploadId, etags);
    } on Object {
      if (uploadId case final String id) {
        try {
          await client.abortMultipartUpload(objectKey, id);
        } on Object {
          // The original failure matters more; a lifecycle rule can still
          // clean the parts up.
        }
      }
      rethrow;
    }
  }

  /// S3 has no append: reads the object and writes it back.
  @override
  Future<void> append(String path, String contents) async {
    final current = await exists(path) ? await get(path) : '';
    await put(path, current.isEmpty ? contents : '$current\n$contents');
  }

  @override
  Future<String> get(String path) async => utf8.decode(await getBytes(path));

  @override
  Future<Uint8List> getBytes(String path) async {
    final response = await client.getObject(key(path));
    if (response == null) {
      throw _notFound(path);
    }
    final builder = BytesBuilder(copy: false);
    // With the client's quiet timeout: a half-open connection would
    // otherwise hold the handler for ever.
    await client.readBody(response, builder.add, client.uri(key(path)));
    return builder.takeBytes();
  }

  @override
  Stream<List<int>> readStream(String path) async* {
    final response = await client.getObject(key(path));
    if (response == null) {
      throw _notFound(path);
    }
    // With the client's quiet timeout, like getBytes.
    yield* client.bodyStream(response, client.uri(key(path)));
  }

  @override
  Future<bool> exists(String path) async =>
      await client.headObject(key(path)) != null;

  @override
  Future<bool> missing(String path) async => !await exists(path);

  /// Checks which [paths] exist (S3's delete does not say), then removes
  /// them in one `DeleteObjects` per thousand.
  @override
  Future<bool> delete(Object paths) async {
    final list = paths is String
        ? <String>[paths]
        : (paths as List<Object?>).cast<String>();
    final keys = list.map(key).toList();
    final found = <String>[];
    for (var start = 0; start < keys.length; start += 16) {
      final batch = keys.skip(start).take(16).toList();
      final heads = await Future.wait(batch.map(client.headObject));
      for (var i = 0; i < batch.length; i++) {
        if (heads[i] != null) {
          found.add(batch[i]);
        }
      }
    }
    if (found.isNotEmpty) {
      final failed = await client.deleteObjects(found);
      if (failed.isNotEmpty) {
        throw S3Exception(
          'S3 could not delete ${failed.map(_relative).join(', ')}.',
          status: 200,
        );
      }
    }
    return found.length == keys.length;
  }

  /// A server-side copy: the bytes never pass through this process.
  @override
  Future<void> copy(String from, String to) async {
    try {
      await client.copyObject(key(from), key(to), headers: _writeHeaders(to));
    } on S3Exception catch (error) {
      if (error.status == 404 && error.code != 'NoSuchBucket') {
        throw _notFound(from);
      }
      rethrow;
    }
  }

  @override
  Future<void> move(String from, String to) async {
    await copy(from, to);
    await client.deleteObject(key(from));
  }

  Future<S3ObjectInfo> _info(String path) async =>
      await client.headObject(key(path)) ?? (throw _notFound(path));

  @override
  Future<int> size(String path) async => (await _info(path)).size;

  @override
  Future<DateTime> lastModified(String path) async =>
      (await _info(path)).lastModified;

  @override
  String url(String path) {
    final objectKey = key(path);
    final base = baseUrl;
    if (base == null) {
      return client.uri(objectKey).toString();
    }
    final trimmed = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return '$trimmed/${awsUriEncode(objectKey, keepSlash: true)}';
  }

  /// A presigned `GET` of [path] that works until [expiration] (at most
  /// seven days away), for private objects. [responseContentType] and
  /// [responseContentDisposition] override what S3 answers with (an
  /// `attachment; filename=...` download, say).
  String temporaryUrl(
    String path, {
    required DateTime expiration,
    String? responseContentType,
    String? responseContentDisposition,
  }) => client.signer
      .presign(
        method: 'GET',
        uri: client.uri(key(path), {
          'response-content-type': ?responseContentType,
          'response-content-disposition': ?responseContentDisposition,
        }),
        now: Clock.now(),
        expires: expiration.difference(Clock.now()),
      )
      .toString();

  /// A presigned `PUT` of [path] until [expiration], for a client to upload
  /// straight to the bucket. [contentType] and [contentLength] are signed,
  /// so S3 rejects an upload of another type or size.
  S3PresignedRequest temporaryUploadUrl(
    String path, {
    required DateTime expiration,
    String? contentType,
    int? contentLength,
  }) {
    final headers = <String, String>{
      'content-type': ?contentType,
      if (contentLength != null) 'content-length': '$contentLength',
      if (visibility == 'public') 'x-amz-acl': 'public-read',
    };
    final url = client.signer.presign(
      method: 'PUT',
      uri: client.uri(key(path)),
      now: Clock.now(),
      expires: expiration.difference(Clock.now()),
      headers: headers,
    );
    return S3PresignedRequest('PUT', url.toString(), headers);
  }

  /// A presigned `POST` form for [path] until [expiration], the way to cap
  /// a direct upload's size: S3 rejects a file over [maxSize] bytes (or
  /// under [minSize]), and a content type other than [contentType] or not
  /// starting with [contentTypePrefix] (then the client adds its own
  /// `Content-Type` field).
  S3PresignedPost temporaryUploadForm(
    String path, {
    required DateTime expiration,
    int? maxSize,
    int minSize = 0,
    String? contentType,
    String? contentTypePrefix,
  }) {
    if (contentType != null && contentTypePrefix != null) {
      throw ArgumentError(
        'Pass either contentType or contentTypePrefix, not both.',
      );
    }
    if (maxSize != null && (maxSize < minSize || minSize < 0)) {
      throw ArgumentError.value(maxSize, 'maxSize', 'Must be >= minSize >= 0.');
    }
    final fields = client.signer.presignPost(
      now: Clock.now(),
      expires: expiration.difference(Clock.now()),
      fields: {
        'key': key(path),
        'Content-Type': ?contentType,
        if (visibility == 'public') 'acl': 'public-read',
      },
      conditions: [
        {'bucket': client.bucket},
        if (maxSize != null) ['content-length-range', minSize, maxSize],
        if (contentTypePrefix != null)
          ['starts-with', r'$Content-Type', contentTypePrefix],
      ],
    );
    return S3PresignedPost(client.uri('').toString(), fields);
  }

  @override
  Future<List<String>> files([
    String directory = '',
    bool recursive = false,
  ]) async {
    final prefix = _dirPrefix(directory);
    final listing = await client.listObjects(
      prefix,
      delimiter: recursive ? null : '/',
    );
    return [
      for (final objectKey in listing.keys)
        if (!objectKey.endsWith('/')) _relative(objectKey),
    ]..sort();
  }

  @override
  Future<List<String>> allFiles([String directory = '']) =>
      files(directory, true);

  @override
  Future<List<String>> directories([
    String directory = '',
    bool recursive = false,
  ]) async {
    final prefix = _dirPrefix(directory);
    if (!recursive) {
      final listing = await client.listObjects(prefix, delimiter: '/');
      return [
        for (final common in listing.prefixes)
          _relative(common.substring(0, common.length - 1)),
      ]..sort();
    }
    final listing = await client.listObjects(prefix);
    final dirs = <String>{};
    for (final objectKey in listing.keys) {
      final parts = objectKey.substring(prefix.length).split('/')..removeLast();
      for (var i = 1; i <= parts.length; i++) {
        dirs.add(_relative('$prefix${parts.take(i).join('/')}'));
      }
    }
    return dirs.toList()..sort();
  }

  @override
  Future<void> makeDirectory(String path) async {
    final dir = normalizeDiskPath(path);
    if (dir.isNotEmpty) {
      await client.putObject('$_prefix$dir/', const []);
    }
  }

  @override
  Future<bool> deleteDirectory(String path) async {
    if (normalizeDiskPath(path).isEmpty) {
      throw const StorageException('Refusing to delete the disk root.');
    }
    final listing = await client.listObjects(_dirPrefix(path));
    if (listing.keys.isEmpty) {
      return false;
    }
    final failed = await client.deleteObjects(listing.keys);
    if (failed.isNotEmpty) {
      throw S3Exception(
        'S3 could not delete ${failed.map(_relative).join(', ')}.',
        status: 200,
      );
    }
    return true;
  }
}
