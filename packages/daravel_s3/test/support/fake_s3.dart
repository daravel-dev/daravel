import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daravel_s3/daravel_s3.dart';
import 'package:daravel_s3/src/xml.dart';
import 'package:mime/mime.dart';

/// An in-process S3 (path-style, one bucket) that checks every request's
/// SigV4 signature, header or presigned, against its own secret: enough of
/// the REST API for [S3Disk], and strict where S3 is.
final class FakeS3 {
  FakeS3._(this._server, this.signer, this.bucket, this.pageSize);

  static Future<FakeS3> start({
    String bucket = 'bucket',
    String accessKey = 'AKIDEXAMPLE',
    String secretKey = 'secret/key+example',
    String region = 'ap-southeast-1',
    int pageSize = 2,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeS3._(
      server,
      SigV4Signer(accessKey: accessKey, secretKey: secretKey, region: region),
      bucket,
      pageSize,
    );
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final SigV4Signer signer;
  final String bucket;

  /// Keys per `ListObjectsV2` page, small so pagination is exercised.
  final int pageSize;

  final Map<String, ({Uint8List bytes, DateTime modified, String type})>
  objects = {};
  final Map<String, Map<int, Uint8List>> _uploads = {};
  var _uploadIds = 0;

  /// `METHOD path?query` of every request, in order.
  final List<String> log = [];

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  S3Config config({String root = '', String? url}) => S3Config(
    accessKey: signer.accessKey,
    secretKey: signer.secretKey,
    region: signer.region,
    bucket: bucket,
    endpoint: endpoint,
    usePathStyleEndpoint: true,
    root: root,
    url: url,
  );

  Future<void> close() => _server.close(force: true);

  /// Runs before every request: answer it and return true to take it over
  /// (a 503, a stall, a dropped connection), or return false to let the
  /// fake serve it.
  Future<bool> Function(HttpRequest request)? fault;

  Future<void> _handle(HttpRequest request) async {
    log.add(
      '${request.method} ${request.uri.path}'
      '${request.uri.hasQuery ? '?${request.uri.query}' : ''}',
    );
    if (await fault?.call(request) ?? false) {
      return;
    }
    final builder = BytesBuilder(copy: false);
    await request.forEach(builder.add);
    final body = builder.takeBytes();
    final response = request.response;
    try {
      // A browser POST upload carries its signature in the form's policy.
      final isForm =
          request.method == 'POST' &&
          request.headers.contentType?.mimeType == 'multipart/form-data';
      final denied = isForm ? null : _verify(request, body);
      if (denied != null) {
        return await _error(response, 403, 'SignatureDoesNotMatch', denied);
      }
      final segments = request.uri.pathSegments;
      if (segments.isEmpty || segments.first != bucket) {
        return await _error(response, 404, 'NoSuchBucket', 'No such bucket.');
      }
      // A trailing slash leaves an empty last segment: `dir/` markers keep it.
      final key = segments.skip(1).join('/');
      final query = request.uri.queryParameters;
      switch ((request.method, key.isEmpty)) {
        case ('GET', true):
          return await _list(response, query);
        case ('POST', true) when isForm:
          return await _postObject(request, response, body);
        case ('POST', true) when query.containsKey('delete'):
          return await _deleteMany(request, response, body);
        case ('POST', false) when query.containsKey('uploads'):
          final id = 'upload-${++_uploadIds}';
          _uploads[id] = {};
          return await _xml(
            response,
            '<InitiateMultipartUploadResult><Key>${xmlEscape(key)}</Key>'
            '<UploadId>$id</UploadId></InitiateMultipartUploadResult>',
          );
        case ('POST', false) when query.containsKey('uploadId'):
          return await _complete(
            response,
            key,
            query['uploadId']!,
            body,
            request,
          );
        case ('PUT', false) when query.containsKey('uploadId'):
          final parts = _uploads[query['uploadId']];
          if (parts == null) {
            return await _error(
              response,
              404,
              'NoSuchUpload',
              'No such upload.',
            );
          }
          parts[int.parse(query['partNumber']!)] = body;
          response.headers.set('etag', '"${md5.convert(body)}"');
          return await response.close();
        case ('PUT', false):
          return await _put(request, response, key, body);
        case ('GET', false) || ('HEAD', false):
          final object = objects[key];
          if (object == null) {
            return await _error(response, 404, 'NoSuchKey', 'No such key.');
          }
          response.headers
            ..contentType = ContentType.parse(object.type)
            ..set('last-modified', HttpDate.format(object.modified))
            ..set('etag', '"${md5.convert(object.bytes)}"')
            ..contentLength = object.bytes.length;
          if (request.method == 'GET') {
            response.add(object.bytes);
          }
          return await response.close();
        case ('DELETE', false) when query.containsKey('uploadId'):
          _uploads.remove(query['uploadId']);
          response.statusCode = 204;
          return await response.close();
        case ('DELETE', false):
          objects.remove(key);
          response.statusCode = 204;
          return await response.close();
      }
      return await _error(response, 405, 'MethodNotAllowed', 'Not supported.');
    } on Object catch (error) {
      return await _error(response, 500, 'InternalError', '$error');
    }
  }

  /// `null` when the request is signed by [signer], else why not.
  String? _verify(HttpRequest request, Uint8List body) {
    final query = request.uri.queryParametersAll;
    final String names;
    final String credential;
    final String amzDate;
    final String signature;
    final String payload;
    Map<String, List<String>> canonicalQuery = query;
    if (query.containsKey('X-Amz-Signature')) {
      names = query['X-Amz-SignedHeaders']!.single;
      credential = query['X-Amz-Credential']!.single;
      amzDate = query['X-Amz-Date']!.single;
      signature = query['X-Amz-Signature']!.single;
      payload = 'UNSIGNED-PAYLOAD';
      canonicalQuery = {...query}..remove('X-Amz-Signature');
      final expires = int.parse(query['X-Amz-Expires']!.single);
      if (DateTime.now().toUtc().isAfter(
        _parseAmzDate(amzDate).add(Duration(seconds: expires)),
      )) {
        return 'Request has expired';
      }
    } else {
      final authorization = request.headers.value('authorization');
      if (authorization == null) {
        return 'Missing Authorization';
      }
      final match = RegExp(
        r'^AWS4-HMAC-SHA256 Credential=([^,]+), ?SignedHeaders=([^,]+), ?'
        r'Signature=([0-9a-f]{64})$',
      ).firstMatch(authorization);
      if (match == null) {
        return 'Malformed Authorization';
      }
      credential = match.group(1)!;
      names = match.group(2)!;
      signature = match.group(3)!;
      amzDate = request.headers.value('x-amz-date') ?? '';
      payload = request.headers.value('x-amz-content-sha256') ?? '';
      if (payload != payloadHash(body)) {
        return 'x-amz-content-sha256 does not match the body';
      }
    }
    final scope = credential.substring(credential.indexOf('/') + 1);
    if (!credential.startsWith('${signer.accessKey}/') ||
        scope !=
            '${amzDate.substring(0, 8)}/${signer.region}/s3/aws4_request') {
      return 'Wrong credential scope $credential';
    }
    final signedHeaders = names.split(';');
    final canonical = SigV4Signer.canonicalRequest(
      method: request.method,
      uri: request.uri.replace(
        query: SigV4Signer.canonicalQuery(canonicalQuery),
      ),
      headers: {
        for (final name in signedHeaders)
          name: request.headers[name]?.join(',') ?? '',
      },
      signedHeaders: signedHeaders,
      payload: payload,
    );
    final expected = signer.signatureOf(
      _parseAmzDate(amzDate),
      [
        'AWS4-HMAC-SHA256',
        amzDate,
        scope,
        sha256.convert(utf8.encode(canonical)).toString(),
      ].join('\n'),
    );
    return expected == signature ? null : 'Signature mismatch';
  }

  /// `POST Object` with a policy, checked as S3 checks it: the signature
  /// over the base64 policy, its expiry, every condition, and that every
  /// form field (but `policy`, `x-amz-signature`, `file`, `x-ignore-*`) is
  /// covered by one.
  Future<void> _postObject(
    HttpRequest request,
    HttpResponse response,
    Uint8List body,
  ) async {
    final boundary = request.headers.contentType!.parameters['boundary']!;
    final fields = <String, String>{};
    Uint8List? file;
    String? lastField;
    await for (final part in MimeMultipartTransformer(
      boundary,
    ).bind(Stream.value(body))) {
      final name = RegExp('name="([^"]*)"')
          .firstMatch(part.headers['content-disposition'] ?? '')!
          .group(1)!;
      final builder = BytesBuilder(copy: false);
      await part.forEach(builder.add);
      lastField = name;
      if (name == 'file') {
        file = builder.takeBytes();
      } else {
        fields[name.toLowerCase()] = utf8.decode(builder.takeBytes());
      }
    }
    if (file == null || lastField != 'file') {
      return _error(response, 400, 'InvalidArgument', 'file must be last.');
    }
    final policy = fields['policy'] ?? '';
    final amzDate = fields['x-amz-date'] ?? '';
    final credential = fields['x-amz-credential'] ?? '';
    if (!credential.startsWith('${signer.accessKey}/') ||
        signer.signatureOf(_parseAmzDate(amzDate), policy) !=
            fields['x-amz-signature']) {
      return _error(response, 403, 'SignatureDoesNotMatch', 'Bad policy.');
    }
    final decoded =
        jsonDecode(utf8.decode(base64.decode(policy))) as Map<String, Object?>;
    if (DateTime.now().toUtc().isAfter(
      DateTime.parse(decoded['expiration']! as String),
    )) {
      return _error(response, 403, 'AccessDenied', 'Policy expired.');
    }
    final covered = <String>{};
    String? failure;
    for (final condition in decoded['conditions']! as List<Object?>) {
      switch (condition) {
        case {'bucket': final Object? value}:
          if (value != bucket) failure = 'bucket';
        case final Map<String, Object?> exact:
          final name = exact.keys.single.toLowerCase();
          covered.add(name);
          if (fields[name] != exact.values.single) failure = name;
        case ['content-length-range', final int min, final int max]:
          if (file.length < min || file.length > max) {
            return _error(
              response,
              400,
              file.length > max ? 'EntityTooLarge' : 'EntityTooSmall',
              'Size outside content-length-range.',
            );
          }
        case ['starts-with', final String field, final String prefix]:
          final name = field.substring(1).toLowerCase();
          covered.add(name);
          if (!(fields[name] ?? '').startsWith(prefix)) failure = name;
        case ['eq', final String field, final String value]:
          final name = field.substring(1).toLowerCase();
          covered.add(name);
          if (fields[name] != value) failure = name;
      }
    }
    final uncovered = fields.keys.where(
      (name) =>
          !covered.contains(name) &&
          !{'policy', 'x-amz-signature'}.contains(name) &&
          !name.startsWith('x-ignore-'),
    );
    if (failure != null || uncovered.isNotEmpty) {
      return _error(
        response,
        403,
        'AccessDenied',
        'Invalid according to Policy: ${failure ?? uncovered.first}',
      );
    }
    objects[fields['key']!] = (
      bytes: file,
      modified: DateTime.now().toUtc(),
      type: fields['content-type'] ?? 'binary/octet-stream',
    );
    response.statusCode = 204;
    return response.close();
  }

  static DateTime _parseAmzDate(String value) => DateTime.utc(
    int.parse(value.substring(0, 4)),
    int.parse(value.substring(4, 6)),
    int.parse(value.substring(6, 8)),
    int.parse(value.substring(9, 11)),
    int.parse(value.substring(11, 13)),
    int.parse(value.substring(13, 15)),
  );

  Future<void> _put(
    HttpRequest request,
    HttpResponse response,
    String key,
    Uint8List body,
  ) {
    final source = request.headers.value('x-amz-copy-source');
    if (source != null) {
      final from = Uri.decodeComponent(source).substring(bucket.length + 2);
      final object = objects[from];
      if (object == null) {
        return _error(response, 404, 'NoSuchKey', 'No such key.');
      }
      objects[key] = (
        bytes: object.bytes,
        modified: DateTime.now().toUtc(),
        type: object.type,
      );
      return _xml(response, '<CopyObjectResult></CopyObjectResult>');
    }
    final length = request.headers.value('content-length');
    if (length == null) {
      return _error(response, 411, 'MissingContentLength', 'No length.');
    }
    objects[key] = (
      bytes: body,
      modified: DateTime.now().toUtc(),
      type: request.headers.value('content-type') ?? 'binary/octet-stream',
    );
    return response.close();
  }

  Future<void> _complete(
    HttpResponse response,
    String key,
    String uploadId,
    Uint8List body,
    HttpRequest request,
  ) {
    final parts = _uploads.remove(uploadId);
    if (parts == null) {
      return _error(response, 404, 'NoSuchUpload', 'No such upload.');
    }
    final numbers = xmlValues(utf8.decode(body), 'PartNumber').map(int.parse);
    final all = BytesBuilder(copy: false);
    for (final number in numbers) {
      all.add(parts[number]!);
    }
    objects[key] = (
      bytes: all.takeBytes(),
      modified: DateTime.now().toUtc(),
      type: 'binary/octet-stream',
    );
    return _xml(
      response,
      '<CompleteMultipartUploadResult><Key>${xmlEscape(key)}</Key>'
      '</CompleteMultipartUploadResult>',
    );
  }

  Future<void> _deleteMany(
    HttpRequest request,
    HttpResponse response,
    Uint8List body,
  ) {
    if (request.headers.value('content-md5') !=
        base64.encode(md5.convert(body).bytes)) {
      return _error(response, 400, 'InvalidDigest', 'Bad Content-MD5.');
    }
    final keys = xmlValues(utf8.decode(body), 'Key');
    if (keys.length > 1000) {
      return _error(response, 400, 'MalformedXML', 'Over 1000 keys.');
    }
    keys.forEach(objects.remove);
    return _xml(response, '<DeleteResult></DeleteResult>');
  }

  Future<void> _list(HttpResponse response, Map<String, String> query) {
    final prefix = query['prefix'] ?? '';
    final delimiter = query['delimiter'];
    // Entry → whether it is a common prefix (S3 rolls everything after the
    // first delimiter past the prefix up into one).
    final entries = <String, bool>{};
    for (final key in objects.keys.where((k) => k.startsWith(prefix))) {
      final rest = key.substring(prefix.length);
      final cut = delimiter == null ? -1 : rest.indexOf(delimiter);
      if (cut < 0) {
        entries[key] = false;
      } else {
        entries['${key.substring(0, prefix.length + cut)}$delimiter'] = true;
      }
    }
    final sorted = entries.keys.toList()..sort();
    final start = int.tryParse(query['continuation-token'] ?? '') ?? 0;
    final page = sorted.skip(start).take(pageSize).toList();
    final truncated = start + pageSize < sorted.length;
    final xml = StringBuffer('<ListBucketResult>')
      ..write('<IsTruncated>$truncated</IsTruncated>');
    if (truncated) {
      xml.write(
        '<NextContinuationToken>${start + pageSize}</NextContinuationToken>',
      );
    }
    for (final entry in page) {
      if (entries[entry]!) {
        xml.write(
          '<CommonPrefixes><Prefix>${xmlEscape(entry)}</Prefix></CommonPrefixes>',
        );
      } else {
        xml.write('<Contents><Key>${xmlEscape(entry)}</Key></Contents>');
      }
    }
    xml.write('</ListBucketResult>');
    return _xml(response, xml.toString());
  }

  Future<void> _xml(HttpResponse response, String xml) {
    response.headers.contentType = ContentType(
      'application',
      'xml',
      charset: 'utf-8',
    );
    response.write('<?xml version="1.0" encoding="UTF-8"?>$xml');
    return response.close();
  }

  Future<void> _error(
    HttpResponse response,
    int status,
    String code,
    String message,
  ) {
    response.statusCode = status;
    return _xml(
      response,
      '<Error><Code>$code</Code><Message>${xmlEscape(message)}</Message>'
      '<RequestId>fake</RequestId></Error>',
    );
  }
}
