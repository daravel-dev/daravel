import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import 'client.dart';
import 'token.dart';

/// A Google service account (its JSON key file) and the access tokens it
/// gets with a signed JWT (RFC 7523, the `jwt-bearer` grant): no user
/// involved, for calendars shared with the account or, with domain-wide
/// delegation, for a Workspace user named as [subject] of [token].
final class GoogleServiceAccount {
  GoogleServiceAccount({
    required this.clientEmail,
    required RSAPrivateKey privateKey,
    this.privateKeyId,
    this.tokenUri = defaultTokenUri,
    this.projectId,
    HttpClientFactory? http,
    this.timeout = const Duration(seconds: 10),
  }) : _key = privateKey,
       _http = GoogleHttp(http);

  /// The key file Google gives (`"type": "service_account"`).
  factory GoogleServiceAccount.fromJson(
    Map<String, Object?> json, {
    HttpClientFactory? http,
  }) {
    if (json['type'] != 'service_account') {
      throw const ConfigException(
        'Google: not a service account key (its "type" is not '
        '"service_account").',
      );
    }
    return GoogleServiceAccount(
      clientEmail: json['client_email']! as String,
      privateKey: parsePrivateKey(json['private_key']! as String),
      privateKeyId: json['private_key_id'] as String?,
      tokenUri: (json['token_uri'] as String?) ?? defaultTokenUri,
      projectId: json['project_id'] as String?,
      http: http,
    );
  }

  /// [GoogleServiceAccount.fromJson] of the key file at [path]
  /// (`GOOGLE_APPLICATION_CREDENTIALS`).
  factory GoogleServiceAccount.fromFile(
    String path, {
    HttpClientFactory? http,
  }) => GoogleServiceAccount.fromJson(
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>,
    http: http,
  );

  static const String defaultTokenUri = 'https://oauth2.googleapis.com/token';
  static const String grantType = 'urn:ietf:params:oauth:grant-type:jwt-bearer';

  final String clientEmail;
  final String? privateKeyId;
  final String tokenUri;
  final String? projectId;
  final Duration timeout;
  final RSAPrivateKey _key;
  final GoogleHttp _http;

  /// The signed JWT that asks for [scopes]: RS256, `iss` the account,
  /// `aud` the token endpoint, valid for an hour from [Clock.now], `sub`
  /// the user to act as when given.
  String assertion({required List<String> scopes, String? subject}) {
    final now = Clock.now().millisecondsSinceEpoch ~/ 1000;
    String part(Map<String, Object?> json) =>
        _base64Url(utf8.encode(jsonEncode(json)));
    final input =
        '${part({'alg': 'RS256', 'typ': 'JWT', 'kid': ?privateKeyId})}.'
        '${part({'iss': clientEmail, 'scope': scopes.join(' '), 'aud': tokenUri, 'iat': now, 'exp': now + 3600, 'sub': ?subject})}';
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(_key));
    final signature = signer.generateSignature(utf8.encode(input));
    return '$input.${_base64Url(signature.bytes)}';
  }

  /// An access token for [scopes], acting as [subject] when given.
  Future<GoogleToken> token({
    required List<String> scopes,
    String? subject,
  }) async {
    final response = await _http.factory
        .request()
        .acceptJson()
        .timeout(timeout)
        .post(
          tokenUri,
          form: {
            'grant_type': grantType,
            'assertion': assertion(scopes: scopes, subject: subject),
          },
        );
    if (!response.successful) {
      throw GoogleException.from(
        'Get a service account token for $clientEmail',
        response,
      );
    }
    return GoogleToken.fromResponse(response.jsonMap());
  }

  /// The RSA key of a PEM `PRIVATE KEY` (PKCS#8, as in Google's key files)
  /// or `RSA PRIVATE KEY` (PKCS#1).
  static RSAPrivateKey parsePrivateKey(String pem) {
    final match = RegExp(
      r'-----BEGIN (RSA )?PRIVATE KEY-----([\s\S]*?)-----END \1?PRIVATE KEY-----',
    ).firstMatch(pem.replaceAll(r'\n', '\n'));
    if (match == null) {
      throw const ConfigException(
        'Google: the private key is not a PEM "PRIVATE KEY".',
      );
    }
    var der = Uint8List.fromList(
      base64.decode(match[2]!.replaceAll(RegExp(r'\s'), '')),
    );
    if (match[1] == null) {
      // PrivateKeyInfo: version, algorithm, privateKey (an OCTET STRING
      // holding the PKCS#1 RSAPrivateKey).
      final info = ASN1Parser(der).nextObject() as ASN1Sequence;
      der = (info.elements![2] as ASN1OctetString).octets!;
    }
    // RSAPrivateKey: version, n, e, d, p, q, ...
    final rsa = ASN1Parser(der).nextObject() as ASN1Sequence;
    BigInt at(int i) => (rsa.elements![i] as ASN1Integer).integer!;
    return RSAPrivateKey(at(1), at(3), at(4), at(5));
  }

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
