import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The SHA-256 of an empty payload, signed by requests without a body.
const String emptyPayloadHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Lowercase hex SHA-256 of [bytes] (the `x-amz-content-sha256` value).
String payloadHash(List<int> bytes) => sha256.convert(bytes).toString();

/// URI-encodes [value] the way SigV4 requires: every byte except the
/// unreserved `A-Z a-z 0-9 - . _ ~` becomes `%XX` (uppercase hex), and `/`
/// stays literal when [keepSlash] (object keys in paths).
String awsUriEncode(String value, {bool keepSlash = false}) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if ((byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E ||
        (keepSlash && byte == 0x2F)) {
      out.writeCharCode(byte);
    } else {
      out
        ..write('%')
        ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// AWS Signature Version 4 (`AWS4-HMAC-SHA256`) for S3 and S3-compatible
/// stores, in pure Dart: the `Authorization` header and query presigning.
///
/// Paths of the [Uri]s given are used as they are, so they must already be
/// encoded with [awsUriEncode] (S3 does not encode them twice).
final class SigV4Signer {
  const SigV4Signer({
    required this.accessKey,
    required this.secretKey,
    required this.region,
    this.service = 's3',
    this.sessionToken,
  });

  final String accessKey;
  final String secretKey;
  final String region;
  final String service;

  /// A temporary credential's token (`AWS_SESSION_TOKEN`), sent as
  /// `x-amz-security-token`.
  final String? sessionToken;

  /// The headers to send [method] [uri] with: [headers] plus `host`,
  /// `x-amz-date`, `x-amz-content-sha256`, the session token when there is
  /// one and `authorization`. Every header given is signed.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    required DateTime now,
    Map<String, String> headers = const {},
    String payload = emptyPayloadHash,
  }) {
    final amzDate = _amzDate(now);
    final signed = <String, String>{
      for (final MapEntry(:key, :value) in headers.entries)
        key.toLowerCase(): value,
      'host': _host(uri),
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payload,
      if (sessionToken case final String token) 'x-amz-security-token': token,
    };
    final names = signed.keys.toList()..sort();
    final canonical = canonicalRequest(
      method: method,
      uri: uri,
      headers: signed,
      signedHeaders: names,
      payload: payload,
    );
    final scope = _scope(now);
    final signature = _signature(now, _stringToSign(amzDate, scope, canonical));
    return {
      ...signed,
      'authorization':
          'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
          'SignedHeaders=${names.join(';')}, Signature=$signature',
    };
  }

  /// [uri] with the `X-Amz-*` query of a presigned URL valid for [expires]
  /// (at most seven days). [headers] are signed too, so the client must
  /// send them unchanged (a `content-type` for an upload, say).
  Uri presign({
    required String method,
    required Uri uri,
    required DateTime now,
    required Duration expires,
    Map<String, String> headers = const {},
  }) {
    if (expires.inSeconds < 1 || expires.inSeconds > 604800) {
      throw ArgumentError.value(
        expires,
        'expires',
        'A presigned URL lives between 1 second and 7 days.',
      );
    }
    final amzDate = _amzDate(now);
    final scope = _scope(now);
    final signed = <String, String>{
      for (final MapEntry(:key, :value) in headers.entries)
        key.toLowerCase(): value,
      'host': _host(uri),
    };
    final names = signed.keys.toList()..sort();
    final query = <String, List<String>>{
      ...uri.queryParametersAll,
      'X-Amz-Algorithm': ['AWS4-HMAC-SHA256'],
      'X-Amz-Credential': ['$accessKey/$scope'],
      'X-Amz-Date': [amzDate],
      'X-Amz-Expires': ['${expires.inSeconds}'],
      'X-Amz-SignedHeaders': [names.join(';')],
      if (sessionToken case final String token) 'X-Amz-Security-Token': [token],
    };
    final unsigned = _withQuery(uri, canonicalQuery(query));
    final canonical = canonicalRequest(
      method: method,
      uri: unsigned,
      headers: signed,
      signedHeaders: names,
      payload: 'UNSIGNED-PAYLOAD',
    );
    final signature = _signature(now, _stringToSign(amzDate, scope, canonical));
    return _withQuery(
      uri,
      canonicalQuery({
        ...query,
        'X-Amz-Signature': [signature],
      }),
    );
  }

  /// The form fields of a browser `POST` upload (S3's POST policy): [fields]
  /// plus the `x-amz-*` credential fields, `policy` (base64 JSON that
  /// expires after [expires]) and `x-amz-signature`, which signs the policy
  /// itself rather than a canonical request.
  ///
  /// Every field becomes an exact-match condition, as S3 requires each
  /// form field to appear in the policy; [conditions] adds the rest
  /// (`["content-length-range", 0, max]`, `["starts-with", "$key", p]`).
  Map<String, String> presignPost({
    required DateTime now,
    required Duration expires,
    Map<String, String> fields = const {},
    List<Object> conditions = const [],
  }) {
    if (expires.inSeconds < 1 || expires.inSeconds > 604800) {
      throw ArgumentError.value(
        expires,
        'expires',
        'A presigned POST policy lives between 1 second and 7 days.',
      );
    }
    final all = <String, String>{
      ...fields,
      'x-amz-algorithm': 'AWS4-HMAC-SHA256',
      'x-amz-credential': '$accessKey/${_scope(now)}',
      'x-amz-date': _amzDate(now),
      if (sessionToken case final String token) 'x-amz-security-token': token,
    };
    final expiry = now.toUtc().add(expires);
    final policy = base64.encode(
      utf8.encode(
        jsonEncode({
          // ISO 8601 to the second, as S3's examples write it.
          'expiration': '${expiry.toIso8601String().substring(0, 19)}Z',
          'conditions': [
            ...conditions,
            for (final MapEntry(:key, :value) in all.entries) {key: value},
          ],
        }),
      ),
    );
    return {
      ...all,
      'policy': policy,
      'x-amz-signature': _signature(now, policy),
    };
  }

  /// The canonical request of SigV4 (step 1), exposed for tests and for
  /// servers that verify signatures.
  static String canonicalRequest({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<String> signedHeaders,
    required String payload,
  }) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return [
      method.toUpperCase(),
      path,
      canonicalQuery(uri.queryParametersAll),
      for (final name in signedHeaders) '$name:${_trim(headers[name] ?? '')}',
      '',
      signedHeaders.join(';'),
      payload,
    ].join('\n');
  }

  /// Query parameters encoded with [awsUriEncode] and sorted by name, then
  /// value.
  static String canonicalQuery(Map<String, List<String>> query) {
    final pairs =
        [
          for (final MapEntry(:key, :value) in query.entries)
            for (final item in value) (awsUriEncode(key), awsUriEncode(item)),
        ]..sort((a, b) {
          final byName = a.$1.compareTo(b.$1);
          return byName != 0 ? byName : a.$2.compareTo(b.$2);
        });
    return pairs.map((pair) => '${pair.$1}=${pair.$2}').join('&');
  }

  /// The signature of [stringToSign] made at [now] (steps 3 and 4), for
  /// servers that verify requests with the same secret.
  String signatureOf(DateTime now, String stringToSign) =>
      _signature(now, stringToSign);

  String _stringToSign(String amzDate, String scope, String canonical) => [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    payloadHash(utf8.encode(canonical)),
  ].join('\n');

  String _signature(DateTime now, String stringToSign) {
    var key = _hmac(utf8.encode('AWS4$secretKey'), _day(now));
    key = _hmac(key, region);
    key = _hmac(key, service);
    key = _hmac(key, 'aws4_request');
    return Hmac(sha256, key).convert(utf8.encode(stringToSign)).toString();
  }

  String _scope(DateTime now) => '${_day(now)}/$region/$service/aws4_request';

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _day(DateTime now) => _amzDate(now).substring(0, 8);

  /// `YYYYMMDDTHHMMSSZ` in UTC.
  static String _amzDate(DateTime now) {
    final utc = now.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}'
        '${two(utc.second)}Z';
  }

  /// `host[:port]`, as an HTTP client sends it (no default port).
  static String _host(Uri uri) =>
      uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;

  static String _trim(String value) =>
      value.trim().replaceAll(RegExp(' +'), ' ');

  static Uri _withQuery(Uri uri, String query) => Uri.parse(
    '${uri.scheme}://${uri.authority}${uri.path.isEmpty ? '/' : uri.path}'
    '${query.isEmpty ? '' : '?$query'}',
  );
}
