import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'signer.dart';
import 'xml.dart';

/// S3 refused a request. [code] is S3's (`NoSuchBucket`, `AccessDenied`,
/// `SignatureDoesNotMatch`, ...) when the response carried one.
final class S3Exception extends DaravelException {
  const S3Exception(
    super.message, {
    required this.status,
    this.code,
    this.requestId,
  });

  final int status;
  final String? code;
  final String? requestId;
}

/// What a `HEAD Object` tells about an object.
typedef S3ObjectInfo = ({int size, DateTime lastModified, String? etag});

/// The objects and common prefixes under a prefix (`ListObjectsV2`, every
/// page).
typedef S3Listing = ({List<String> keys, List<String> prefixes});

/// The S3 REST calls the disk is made of, over `dart:io` so bodies stay
/// binary and downloads stream. Keys are full object keys (no disk root).
final class S3Client {
  S3Client({
    required this.signer,
    required this.bucket,
    String? endpoint,
    this.pathStyle = false,
    this.timeout = const Duration(minutes: 5),
    this.retries = 3,
    this.retryDelay = const Duration(milliseconds: 100),
    HttpClient Function()? httpClient,
  }) : endpoint = Uri.parse(
         endpoint ?? 'https://s3.${signer.region}.amazonaws.com',
       ),
       _httpClient = httpClient ?? HttpClient.new;

  final SigV4Signer signer;
  final String bucket;
  final Uri endpoint;

  /// `endpoint/bucket/key` rather than `bucket.endpoint/key`.
  final bool pathStyle;

  /// How long a request may take to send its body and get its response
  /// headers, and then how long its body may go quiet while read. A
  /// request that times out is aborted, so its socket is not left waiting
  /// for an answer nobody reads.
  final Duration timeout;

  /// How many more times a call is sent when the connection failed or S3
  /// answered 500, 502, 503 (`SlowDown`) or 504, as the AWS SDKs do: the
  /// wait is [retryDelay] doubled each time with jitter, capped at 20 s.
  /// Every call carries its whole body in memory, so a resend is exact,
  /// and every S3 call here is idempotent.
  final int retries;
  final Duration retryDelay;

  final HttpClient Function() _httpClient;
  HttpClient? _client;

  static final Random _random = Random.secure();

  /// The wait before retry number [attempt] (from 0): equal jitter on an
  /// exponential base.
  Duration backoff(int attempt) {
    const cap = Duration(seconds: 20);
    final base = retryDelay.inMicroseconds * (1 << attempt);
    final capped = base < cap.inMicroseconds ? base : cap.inMicroseconds;
    final half = capped ~/ 2;
    return Duration(microseconds: half + _random.nextInt(half + 1));
  }

  static bool _retryable(int status) =>
      status == 500 || status == 502 || status == 503 || status == 504;

  /// The URL of [key] (empty for the bucket), with [query] in canonical
  /// order.
  Uri uri(String key, [Map<String, String> query = const {}]) {
    final encoded = awsUriEncode(key, keepSlash: true);
    final base = endpoint.path.endsWith('/')
        ? endpoint.path.substring(0, endpoint.path.length - 1)
        : endpoint.path;
    final String authority;
    final String path;
    if (pathStyle) {
      authority = endpoint.authority;
      path = key.isEmpty ? '$base/$bucket' : '$base/$bucket/$encoded';
    } else {
      authority = '$bucket.${endpoint.authority}';
      path = '$base/$encoded';
    }
    final canonical = SigV4Signer.canonicalQuery({
      for (final MapEntry(:key, :value) in query.entries) key: [value],
    });
    return Uri.parse(
      '${endpoint.scheme}://$authority$path'
      '${canonical.isEmpty ? '' : '?$canonical'}',
    );
  }

  /// Sends a signed request and returns the response unread, so its body
  /// can stream. Fails with [S3Exception] unless the status is in [accept].
  Future<HttpClientResponse> open(
    String method,
    String key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int> body = const [],
    Set<int> accept = const {200},
  }) async {
    final target = uri(key, query);
    final signed = signer.sign(
      method: method,
      uri: target,
      now: DateTime.now(),
      headers: headers,
      payload: body.isEmpty ? emptyPayloadHash : payloadHash(body),
    );
    final client = _client ??= _httpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 15);
    HttpClientResponse response;
    for (var attempt = 0; ; attempt++) {
      HttpClientRequest? request;
      try {
        request = await client.openUrl(method, target).timeout(timeout);
        for (final MapEntry(:key, :value) in signed.entries) {
          if (key != 'host') {
            request.headers.set(key, value, preserveHeaderCase: true);
          }
        }
        request.contentLength = body.length;
        if (body.isNotEmpty) {
          request.add(body);
        }
        response = await request.close().timeout(timeout);
      } on TimeoutException {
        // Future.timeout does not cancel the request: without the abort
        // the answer would arrive to nobody and the socket stay out of the
        // pool for as long as the peer kept it.
        request?.abort();
        throw ConnectionException(
          'S3 $method $target timed out after ${timeout.inSeconds}s.',
          isTimeout: true,
        );
      } on SocketException catch (error) {
        if (attempt < retries) {
          await Future<void>.delayed(backoff(attempt));
          continue;
        }
        throw ConnectionException('Could not reach $target: ${error.message}');
      } on io.HttpException catch (error) {
        // The connection closed before any response (a reset, a node
        // going away): nothing was processed, so the call is sent again.
        if (attempt < retries) {
          await Future<void>.delayed(backoff(attempt));
          continue;
        }
        throw ConnectionException('HTTP error for $target: ${error.message}');
      }
      if (attempt < retries &&
          !accept.contains(response.statusCode) &&
          _retryable(response.statusCode)) {
        // S3 asks for exactly this on 503 SlowDown and 500 InternalError.
        await _drain(response, target);
        await Future<void>.delayed(backoff(attempt));
        continue;
      }
      break;
    }
    if (!accept.contains(response.statusCode)) {
      // Reading (or draining) the body returns the connection to the pool.
      final text = method == 'HEAD'
          ? await _drain(response, target)
          : await _readText(response, target);
      throw S3Exception(
        'S3 $method ${key.isEmpty ? bucket : key}: '
        '${xmlValue(text, 'Message') ?? xmlValue(text, 'Code') ?? 'HTTP ${response.statusCode}'}',
        status: response.statusCode,
        code: xmlValue(text, 'Code'),
        requestId:
            xmlValue(text, 'RequestId') ??
            response.headers.value('x-amz-request-id'),
      );
    }
    return response;
  }

  /// [open], with the whole body read.
  Future<({HttpClientResponse response, Uint8List body})> send(
    String method,
    String key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int> body = const [],
    Set<int> accept = const {200},
  }) async {
    final response = await open(
      method,
      key,
      query: query,
      headers: headers,
      body: body,
      accept: accept,
    );
    final builder = BytesBuilder(copy: false);
    await readBody(response, builder.add, uri(key, query));
    return (response: response, body: builder.takeBytes());
  }

  /// Reads [response]'s body through [onChunk], failing with
  /// [ConnectionException] when it goes quiet for [timeout] (a half-open
  /// connection would otherwise hold the handler, and the socket, for
  /// ever); the socket is destroyed then, not returned to the pool.
  Future<void> readBody(
    HttpClientResponse response,
    void Function(List<int> chunk) onChunk,
    Uri target,
  ) async {
    try {
      await response
          .timeout(
            timeout,
            onTimeout: (sink) => sink.addError(
              ConnectionException(
                'S3 response body from $target went quiet for '
                '${timeout.inSeconds}s.',
                isTimeout: true,
              ),
            ),
          )
          .forEach(onChunk);
    } on ConnectionException {
      response.detachSocket().then((socket) => socket.destroy()).ignore();
      rethrow;
    } on io.HttpException catch (error) {
      // Closed while receiving: the same failure as a reset, named alike.
      throw ConnectionException(
        'S3 response body from $target was cut off: ${error.message}',
      );
    }
  }

  Future<String> _drain(HttpClientResponse response, Uri target) async {
    await readBody(response, (_) {}, target);
    return '';
  }

  Future<String> _readText(HttpClientResponse response, Uri target) async {
    final builder = BytesBuilder(copy: false);
    await readBody(response, builder.add, target);
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<void> putObject(
    String key,
    List<int> bytes, {
    Map<String, String> headers = const {},
  }) => send('PUT', key, headers: headers, body: bytes);

  /// The object's body as it downloads; `null` when there is no [key].
  Future<HttpClientResponse?> getObject(String key) async {
    final response = await open('GET', key, accept: const {200, 404});
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    return response;
  }

  /// `null` when there is no [key].
  Future<S3ObjectInfo?> headObject(String key) async {
    final response = await open('HEAD', key, accept: const {200, 404});
    await response.drain<void>();
    if (response.statusCode == 404) {
      return null;
    }
    final modified = response.headers.value('last-modified');
    return (
      size: response.contentLength < 0 ? 0 : response.contentLength,
      lastModified: modified == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : HttpDate.parse(modified),
      etag: response.headers.value('etag'),
    );
  }

  /// Server-side copy (`x-amz-copy-source`), up to 5 GB.
  Future<void> copyObject(
    String from,
    String to, {
    Map<String, String> headers = const {},
  }) async {
    final result = await send(
      'PUT',
      to,
      headers: {
        ...headers,
        'x-amz-copy-source': '/$bucket/${awsUriEncode(from, keepSlash: true)}',
      },
    );
    // A copy can fail after the 200 has been sent: S3 then answers with an
    // <Error> body.
    final text = utf8.decode(result.body, allowMalformed: true);
    if (text.contains('<Error>')) {
      throw S3Exception(
        'S3 copy $from → $to: ${xmlValue(text, 'Message') ?? 'failed'}',
        status: 200,
        code: xmlValue(text, 'Code'),
        requestId: xmlValue(text, 'RequestId'),
      );
    }
  }

  /// Deletes one object (S3 answers 204 whether it existed or not).
  Future<void> deleteObject(String key) =>
      send('DELETE', key, accept: const {200, 204});

  /// Deletes [keys] with `DeleteObjects`, a thousand per request; returns
  /// the keys S3 reported errors for.
  Future<List<String>> deleteObjects(List<String> keys) async {
    final failed = <String>[];
    for (var start = 0; start < keys.length; start += 1000) {
      final batch = keys.sublist(
        start,
        start + 1000 > keys.length ? keys.length : start + 1000,
      );
      final body = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        '<Quiet>true</Quiet>'
        '${batch.map((key) => '<Object><Key>${xmlEscape(key)}</Key></Object>').join()}'
        '</Delete>',
      );
      final result = await send(
        'POST',
        '',
        query: const {'delete': ''},
        headers: {
          'content-type': 'application/xml',
          'content-md5': base64.encode(md5.convert(body).bytes),
        },
        body: body,
      );
      for (final error in xmlBlocks(utf8.decode(result.body), 'Error')) {
        if (xmlValue(error, 'Key') case final String key) {
          failed.add(key);
        }
      }
    }
    return failed;
  }

  /// Every key under [prefix] (and, with a [delimiter], the common
  /// prefixes directly below it), following continuation tokens.
  Future<S3Listing> listObjects(String prefix, {String? delimiter}) async {
    final keys = <String>[];
    final prefixes = <String>[];
    String? token;
    do {
      final result = await send(
        'GET',
        '',
        query: {
          'list-type': '2',
          'prefix': prefix,
          'delimiter': ?delimiter,
          'continuation-token': ?token,
        },
      );
      final xml = utf8.decode(result.body);
      for (final block in xmlBlocks(xml, 'Contents')) {
        if (xmlValue(block, 'Key') case final String key) {
          keys.add(key);
        }
      }
      for (final block in xmlBlocks(xml, 'CommonPrefixes')) {
        if (xmlValue(block, 'Prefix') case final String common) {
          prefixes.add(common);
        }
      }
      token = xmlValue(xml, 'IsTruncated') == 'true'
          ? xmlValue(xml, 'NextContinuationToken')
          : null;
    } while (token != null);
    return (keys: keys, prefixes: prefixes);
  }

  /// Starts a multipart upload and returns its id.
  Future<String> createMultipartUpload(
    String key, {
    Map<String, String> headers = const {},
  }) async {
    final result = await send(
      'POST',
      key,
      query: const {'uploads': ''},
      headers: headers,
    );
    final id = xmlValue(utf8.decode(result.body), 'UploadId');
    if (id == null) {
      throw S3Exception(
        'S3 multipart upload of $key: no UploadId in the response.',
        status: result.response.statusCode,
      );
    }
    return id;
  }

  /// Uploads part [number] (from 1) and returns its ETag.
  Future<String> uploadPart(
    String key,
    String uploadId,
    int number,
    List<int> bytes,
  ) async {
    final result = await send(
      'PUT',
      key,
      query: {'partNumber': '$number', 'uploadId': uploadId},
      body: bytes,
    );
    final etag = result.response.headers.value('etag');
    if (etag == null) {
      throw S3Exception(
        'S3 multipart upload of $key: part $number has no ETag.',
        status: result.response.statusCode,
      );
    }
    return etag;
  }

  Future<void> completeMultipartUpload(
    String key,
    String uploadId,
    List<String> etags,
  ) async {
    final body = utf8.encode(
      '<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
      '${[for (var i = 0; i < etags.length; i++) '<Part><PartNumber>${i + 1}</PartNumber><ETag>${xmlEscape(etags[i])}</ETag></Part>'].join()}'
      '</CompleteMultipartUpload>',
    );
    final result = await send(
      'POST',
      key,
      query: {'uploadId': uploadId},
      headers: const {'content-type': 'application/xml'},
      body: body,
    );
    // Like a copy, completion reports late failures in a 200 body.
    final text = utf8.decode(result.body, allowMalformed: true);
    if (text.contains('<Error>')) {
      throw S3Exception(
        'S3 multipart upload of $key: ${xmlValue(text, 'Message') ?? 'failed'}',
        status: 200,
        code: xmlValue(text, 'Code'),
      );
    }
  }

  Future<void> abortMultipartUpload(String key, String uploadId) => send(
    'DELETE',
    key,
    query: {'uploadId': uploadId},
    accept: const {200, 204, 404},
  );

  /// Closes pooled connections.
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
