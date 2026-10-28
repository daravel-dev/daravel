import 'dart:convert';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';

import 'crypto.dart';
import 'sessions.dart';
import 'setup.dart';

/// `teobiefy`: teobiefy's v1 payload encryption, as a Laravel API
/// implements it, so that API's web and mobile clients talk to Daravel
/// unchanged.
///
/// - A request body with `data_enc` and `nonce` is decrypted with the
///   session's `rx` key (ChaCha20-Poly1305 IETF) and its JSON object merged
///   into the input, `data_enc` and `nonce` removed.
/// - The `data` of a JSON response is encrypted with the session's `tx`:
///   `json_encode`d, zstd-framed, base64 (unless
///   `LIBSODIUM_PAYLOAD_V2_ENABLED`, which sets `enc_v: 2` and skips it),
///   then sealed into `data_enc` + `nonce`.
/// - Without a session (`X-Session-Id`) and without the legacy key, the
///   answer is `409` with `type: SESSION_KEY_REQUIRED`, never plain data;
///   a body that does not decrypt is `406 Invalid payload`.
///
/// Put it on the routes whose payloads are encrypted, as the Laravel
/// application lists them; not on the handshake (`Teobiefy.handshake`).
final class TeobiefyMiddleware implements Middleware {
  const TeobiefyMiddleware();

  @override
  Future<Response> handle(Request request, Next next) async {
    final service = Teobiefy.service;
    SessionKeys? keys;
    var looked = false;
    Future<SessionKeys?> session() async {
      if (!looked) {
        looked = true;
        keys = await service.sessions.find(
          request.header(TeobiefySessions.header),
        );
      }
      return keys;
    }

    final body = await request.body();
    if (body is Map<Object?, Object?> && body['data_enc'] != null) {
      final key = (await session())?.rx ?? service.legacyKey;
      if (key == null) {
        return Teobiefy.sessionKeyRequired();
      }
      try {
        final nonce = TeobiefyCrypto.strictBase64(body['nonce']);
        final sealed = TeobiefyCrypto.strictBase64(body['data_enc']);
        if (nonce == null || sealed == null) {
          throw const FormatException('data_enc or nonce is not base64.');
        }
        final payload = jsonDecode(
          utf8.decode(await TeobiefyCrypto.open(sealed, key, nonce)),
        );
        if (payload is! Map<String, Object?>) {
          throw const FormatException('The payload is not a JSON object.');
        }
        request.replace(
          {
            for (final MapEntry(:key, :value) in body.entries) '$key': value,
            ...payload,
          }..removeWhere((k, _) => k == 'nonce' || k == 'data_enc'),
        );
      } on Object catch (error) {
        Log.warning('Teobiefy: invalid payload: $error');
        return Teobiefy.invalidPayload();
      }
    }

    final response = await next(request);
    if (request.attributes[Teobiefy.handshakeAttribute] == true) {
      // The client has no key before its handshake.
      return response;
    }
    return _encrypt(response, session, service);
  }

  static Future<Response> _encrypt(
    Response response,
    Future<SessionKeys?> Function() session,
    TeobiefyService service,
  ) async {
    if (!(response.headers.first('content-type') ?? '').contains('json')) {
      return response;
    }
    // Read once (a stream body cannot be read twice), answered as read when
    // there is nothing to encrypt.
    final raw = await response.bodyBytes();
    Response unchanged() => Response(
      status: response.status,
      headers: response.headers,
      body: BytesBody(raw),
    );
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return unchanged();
    }
    if (json is! Map<String, Object?> || !json.containsKey('data')) {
      return unchanged();
    }
    final key = (await session())?.tx ?? service.legacyKey;
    if (key == null) {
      return Teobiefy.sessionKeyRequired();
    }
    final v2 = service.config.payloadV2;
    final framed = TeobiefyCrypto.zstdFrame(
      utf8.encode(jsonEncode(json['data'])),
    );
    final message = v2 ? framed : utf8.encode(base64.encode(framed));
    final nonce = TeobiefyCrypto.nonce();
    final sealed = await TeobiefyCrypto.seal(message, key, nonce);
    final encrypted = <String, Object?>{
      for (final MapEntry(:key, :value) in json.entries)
        if (key != 'data') key: value,
      if (v2) 'enc_v': 2,
      'data_enc': base64.encode(sealed),
      'nonce': base64.encode(nonce),
    };
    return Response(
      status: response.status,
      headers: response.headers,
      body: BytesBody(Uint8List.fromList(utf8.encode(jsonEncode(encrypted)))),
    );
  }
}
