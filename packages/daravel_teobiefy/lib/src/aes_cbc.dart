import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:daravel/daravel.dart';

import 'crypto.dart';
import 'setup.dart';

/// The `{"data_enc": "...", "iv": "..."}` envelope of a Laravel API that
/// encrypts responses with OpenSSL instead of libsodium (an
/// obiefy/api-response override such as `App\Helpers\OpenSslHelper`):
///
/// ```php
/// $key = base64_decode(config('openssl.openssl_key')); // 32 bytes
/// $iv = random_bytes(16);
/// $json['data_enc'] = base64_encode(openssl_encrypt(
///     json_encode($json['data']), 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv));
/// $json['iv'] = base64_encode($iv);
/// unset($json['data']);
/// ```
///
/// AES-256-CBC with PKCS#7 padding, a static 32-byte key and a random
/// 16-byte IV per message, both base64; the other keys of the envelope
/// (`status`, `message`, `data_count`) stay in clear. The web clients of
/// such an API (a `DecryptInterceptor`) open it with the same key.
///
/// **This mode has no MAC.** A static key shipped to browsers hides
/// nothing from anyone who has the client, and without authentication a
/// ciphertext can be altered without the server noticing (CBC padding
/// oracles included). It exists so that an API ported from Laravel keeps
/// its clients working; for new work use the X25519 + ChaCha20-Poly1305
/// protocol (`withTeobiefy()`, the `teobiefy` middleware), and migrate the
/// clients when you can.
final class TeobiefyAesCbc {
  /// A cipher with [key] (32 bytes, [ArgumentError] otherwise).
  TeobiefyAesCbc(List<int> key) : _key = SecretKey(List<int>.of(key)) {
    if (key.length != keyLength) {
      throw ArgumentError.value(
        key.length,
        'key',
        'must be $keyLength bytes (AES-256)',
      );
    }
  }

  /// A cipher from a key as `.env` writes it: base64 of 32 bytes, with or
  /// without the `base64:` prefix of `APP_KEY` (see [parseKey]).
  factory TeobiefyAesCbc.fromKey(String key) => TeobiefyAesCbc(parseKey(key));

  /// The key in bytes.
  static const int keyLength = 32;

  /// The IV (one AES block) in bytes.
  static const int ivLength = 16;

  static final AesCbc _cipher = AesCbc.with256bits(
    macAlgorithm: MacAlgorithm.empty,
  );
  static final Random _random = Random.secure();

  final SecretKey _key;

  /// The cipher the application configured (`withTeobiefyAesCbc()`).
  static TeobiefyAesCbc get current => Container.current.make<TeobiefyAesCbc>();

  /// `base64_decode($key)`, after the optional `base64:` prefix; the result
  /// must be [keyLength] bytes. [ArgumentError] otherwise.
  static Uint8List parseKey(String value) {
    final raw = value.startsWith('base64:') ? value.substring(7) : value;
    final key = TeobiefyCrypto.strictBase64(raw.trim());
    if (key == null || key.length != keyLength) {
      throw ArgumentError.value(
        value.isEmpty ? '' : '********',
        'key',
        'must be base64 of $keyLength bytes (optionally prefixed base64:)',
      );
    }
    return key;
  }

  /// `random_bytes(16)`: a fresh IV.
  static Uint8List randomIv() => Uint8List.fromList([
    for (var i = 0; i < ivLength; i++) _random.nextInt(256),
  ]);

  /// `openssl_encrypt($clear, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv)`:
  /// the ciphertext with PKCS#7 padding (always a multiple of 16 bytes,
  /// one block more than [clear] fills). [iv] is random unless given (give
  /// it only in tests: an IV must never repeat under one key).
  Future<Uint8List> encryptBytes(List<int> clear, {List<int>? iv}) async {
    final nonce = iv ?? randomIv();
    if (nonce.length != ivLength) {
      throw ArgumentError.value(nonce.length, 'iv', 'must be $ivLength bytes');
    }
    final box = await _cipher.encrypt(clear, secretKey: _key, nonce: nonce);
    return Uint8List.fromList(box.cipherText);
  }

  /// `openssl_decrypt`: the clear bytes, padding removed. [FormatException]
  /// when [cipherText] or [iv] has not the length of AES blocks or the
  /// padding does not check out (a wrong key or an altered message; with no
  /// MAC, an altered message can also decrypt to garbage silently).
  Future<Uint8List> decryptBytes(List<int> cipherText, List<int> iv) async {
    if (iv.length != ivLength) {
      throw FormatException('The iv is not $ivLength bytes.');
    }
    if (cipherText.isEmpty || cipherText.length % ivLength != 0) {
      throw const FormatException(
        'The ciphertext is not a whole number of AES blocks.',
      );
    }
    try {
      final clear = await _cipher.decrypt(
        SecretBox(cipherText, nonce: iv, mac: Mac.empty),
        secretKey: _key,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxPaddingError catch (error) {
      throw FormatException('The padding is invalid: ${error.message}');
    }
  }

  /// [json] encoded (`json_encode`) and encrypted under a fresh IV:
  /// `{"data_enc": base64(ciphertext), "iv": base64(iv)}`.
  Future<Map<String, Object?>> encrypt(Object? json) async {
    final iv = randomIv();
    final cipherText = await encryptBytes(
      utf8.encode(jsonEncode(json)),
      iv: iv,
    );
    return <String, Object?>{
      'data_enc': base64.encode(cipherText),
      'iv': base64.encode(iv),
    };
  }

  /// The JSON value inside [envelope] (`data_enc` and `iv`, base64).
  /// [FormatException] when either is missing or not base64, when the
  /// ciphertext does not decrypt (see [decryptBytes]) or when the clear
  /// text is not JSON.
  Future<Object?> decrypt(Map<Object?, Object?> envelope) async {
    final cipherText = TeobiefyCrypto.strictBase64(envelope['data_enc']);
    final iv = TeobiefyCrypto.strictBase64(envelope['iv']);
    if (cipherText == null || iv == null) {
      throw const FormatException('data_enc or iv is missing or not base64.');
    }
    final clear = await decryptBytes(cipherText, iv);
    try {
      return jsonDecode(utf8.decode(clear));
    } on FormatException {
      throw const FormatException('The decrypted payload is not JSON.');
    }
  }

  /// `OpenSslHelper::encrypt($json)`: [envelope] with its [key] (`data`)
  /// replaced by `data_enc` and `iv`, the other keys as they were. An
  /// envelope without [key] is returned as it is.
  Future<Map<String, Object?>> seal(
    Map<String, Object?> envelope, {
    String key = 'data',
  }) async {
    if (!envelope.containsKey(key)) {
      return envelope;
    }
    final sealed = await encrypt(envelope[key]);
    return <String, Object?>{
      for (final MapEntry(key: k, :value) in envelope.entries)
        if (k != key) k: value,
      ...sealed,
    };
  }
}

/// The OpenSSL envelope's setting: the key, under the name the Laravel
/// application reads (`OPENSSL_KEY` by default, `config/openssl.php`).
final class TeobiefyAesCbcConfig implements ConfigSection {
  const TeobiefyAesCbcConfig({
    this.encodedKey = '',
    this.variable = 'OPENSSL_KEY',
  });

  /// [variable] from [env]; empty when it is not set, which [check]
  /// reports.
  factory TeobiefyAesCbcConfig.fromEnv(
    Env env, {
    String variable = 'OPENSSL_KEY',
  }) => TeobiefyAesCbcConfig(
    encodedKey: env.string(variable, ''),
    variable: variable,
  );

  /// Base64 of the 32-byte key, with or without `base64:`.
  final String encodedKey;

  /// The `.env` variable [encodedKey] came from (for messages).
  final String variable;

  /// Fails boot when the key is missing or is not base64 of 32 bytes.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final section = config.section<TeobiefyAesCbcConfig>();
    try {
      TeobiefyAesCbc.parseKey(section.encodedKey);
    } on ArgumentError {
      return [
        ConfigIssue(
          ConfigIssueLevel.error,
          'Teobiefy: ${section.variable} must be base64 of 32 bytes '
          '(the key the Laravel application reads from config/openssl.php).',
        ),
      ];
    }
    return const [];
  }

  @override
  String get key => 'teobiefy_aes';

  @override
  Map<String, Object?> toMap() => {
    'variable': variable,
    'key': encodedKey.isEmpty ? '' : '********',
  };
}

/// `teobiefy.aes`: the OpenSSL envelope on selected routes. Opt in per
/// route; the alias takes parameters, comma separated:
///
/// - none: the `data` of a JSON object response is replaced by `data_enc`
///   and `iv` (`OpenSslHelper::encrypt`); a JSON response without `data`,
///   one already sealed, and anything that is not JSON pass as they are.
/// - `body`: the whole JSON body, whatever it is, becomes
///   `{"data_enc": ..., "iv": ...}`.
/// - `decrypt`: a request body `{"data_enc": ..., "iv": ...}` is decrypted
///   and its JSON object merged into the input (clear keys sent beside it
///   stay, the payload winning; `data_enc` and `iv` are removed). A body
///   that does not decrypt is `406 Invalid payload`. Clear bodies still
///   pass: this mode cannot tell a client without the key from one that
///   chose not to encrypt.
///
/// ```dart
/// router.post('/admin/v1/user/login', AuthController.login)
///     .middleware(const ['teobiefy.aes']);
/// router.post('/legacy/submit', Legacy.submit)
///     .middleware(const ['teobiefy.aes:body,decrypt']);
/// ```
///
/// The status code and the headers of the response are kept; the body
/// stays `application/json`. See [TeobiefyAesCbc] for what this mode does
/// not protect.
final class TeobiefyAesCbcMiddleware implements Middleware {
  const TeobiefyAesCbcMiddleware({
    this.decryptRequests = false,
    this.wholeBody = false,
  });

  /// The alias parameters (`decrypt`, `body`); [ArgumentError] for any
  /// other.
  factory TeobiefyAesCbcMiddleware.fromParams(List<String> params) {
    var decrypt = false;
    var body = false;
    for (final param in params) {
      switch (param) {
        case '':
          break;
        case 'decrypt':
          decrypt = true;
        case 'body':
          body = true;
        default:
          throw ArgumentError.value(
            param,
            'params',
            'teobiefy.aes accepts "decrypt" and "body"',
          );
      }
    }
    return TeobiefyAesCbcMiddleware(decryptRequests: decrypt, wholeBody: body);
  }

  /// Decrypt a request body sent as `{data_enc, iv}`.
  final bool decryptRequests;

  /// Encrypt the whole JSON body instead of the `data` of an envelope.
  final bool wholeBody;

  @override
  Future<Response> handle(Request request, Next next) async {
    final cipher = TeobiefyAesCbc.current;
    if (decryptRequests) {
      final body = await request.body();
      if (body is Map<Object?, Object?> &&
          (body.containsKey('data_enc') || body.containsKey('iv'))) {
        try {
          final payload = await cipher.decrypt(body);
          if (payload is! Map<Object?, Object?>) {
            throw const FormatException('The payload is not a JSON object.');
          }
          request.replace({
            for (final MapEntry(:key, :value) in body.entries)
              if (key != 'data_enc' && key != 'iv') '$key': value,
            for (final MapEntry(:key, :value) in payload.entries) '$key': value,
          });
        } on FormatException catch (error) {
          Log.warning('Teobiefy (AES-CBC): invalid payload: ${error.message}');
          return Teobiefy.invalidPayload();
        }
      }
    }
    return _encrypt(await next(request), cipher);
  }

  Future<Response> _encrypt(Response response, TeobiefyAesCbc cipher) async {
    if (!(response.headers.first('content-type') ?? '').contains('json')) {
      return response;
    }
    // Read once (a stream body cannot be read twice), answered as read when
    // there is nothing to encrypt.
    final raw = await response.bodyBytes();
    Response withBody(List<int> body) => Response(
      status: response.status,
      headers: response.headers,
      body: BytesBody(Uint8List.fromList(body)),
    );
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return withBody(raw);
    }
    final Map<String, Object?> sealed;
    if (wholeBody) {
      sealed = await cipher.encrypt(json);
    } else if (json is Map<String, Object?> &&
        json.containsKey('data') &&
        !json.containsKey('data_enc')) {
      sealed = await cipher.seal(json);
    } else {
      return withBody(raw);
    }
    return withBody(utf8.encode(jsonEncode(sealed)));
  }
}

/// `withTeobiefyAesCbc()` on the application builder.
extension TeobiefyAesCbcApplicationBuilder on ApplicationBuilder {
  /// Adds the OpenSSL envelope: [TeobiefyAesCbcConfig] from `.env`
  /// ([variable], `OPENSSL_KEY`; boot fails when it is not a key), the
  /// [TeobiefyAesCbc] singleton and the `teobiefy.aes` middleware alias.
  /// Independent of `withTeobiefy()`: use either or both.
  ApplicationBuilder withTeobiefyAesCbc({String variable = 'OPENSSL_KEY'}) =>
      withConfig<TeobiefyAesCbcConfig>(
            (env) => TeobiefyAesCbcConfig.fromEnv(env, variable: variable),
          )
          .withConfigCheck(TeobiefyAesCbcConfig.check)
          .withBindings(
            (container) => container.singleton<TeobiefyAesCbc>(
              (c) => TeobiefyAesCbc.fromKey(
                c
                    .make<ConfigRepository>()
                    .section<TeobiefyAesCbcConfig>()
                    .encodedKey,
              ),
            ),
          )
          .withMiddleware(
            (middleware) => middleware.aliasFactory(
              'teobiefy.aes',
              TeobiefyAesCbcMiddleware.fromParams,
            ),
          );
}
