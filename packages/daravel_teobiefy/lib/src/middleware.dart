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
    // An empty header is no session, like a missing one.
    final presented = request.header(TeobiefySessions.header);
    final sessionId = presented == null || presented.isEmpty ? null : presented;
    SessionKeys? keys;
    var looked = false;
    Future<SessionKeys?> session() async {
      if (!looked) {
        looked = true;
        keys = await service.sessions.find(sessionId);
      }
      return keys;
    }

    // The key of a request or response: the session's, else the legacy key
    // for a client that presents no session at all. A client that presents
    // an id the store does not know (expired, another server) gets 409
    // and handshakes again; the legacy key would only have given it a 406
    // it cannot act on. Null means 409.
    Future<Uint8List?> keyFor(Uint8List Function(SessionKeys keys) pick) async {
      final found = await session();
      if (found != null) {
        return pick(found);
      }
      return sessionId == null ? service.legacyKey : null;
    }

    final body = await request.body();
    if (body is Map<Object?, Object?> && body['data_enc'] != null) {
      final key = await keyFor((keys) => keys.rx);
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
        // Only after the tag checked out, so a forged body cannot burn a
        // nonce; a body seen before is a replay, whatever it decrypts to.
        if (!await service.sessions.useNonce(
          keys == null ? 'legacy' : sessionId!,
          nonce,
        )) {
          throw const FormatException('The nonce was already used.');
        }
        // As the Laravel application: clear keys beside data_enc are merged
        // (the payload wins). With LIBSODIUM_STRICT_PAYLOAD only the payload
        // reaches the handler, so a client cannot slip a clear field past
        // the encryption.
        request.replace(
          {
            if (!service.config.strictPayload)
              for (final MapEntry(:key, :value) in body.entries) '$key': value,
            ...payload,
          }..removeWhere((k, _) => k == 'nonce' || k == 'data_enc'),
        );
      } on Object catch (error) {
        Log.warning('Teobiefy: invalid payload: $error');
        return Teobiefy.invalidPayload();
      }
    } else if (body is Map<Object?, Object?> && body.isNotEmpty) {
      // A clear body where an encrypted one belongs, from a client with no
      // key to answer with: refused here, before the handler runs on it.
      // The 409 used to come only after the handler had done its work.
      if (await keyFor((keys) => keys.rx) == null) {
        return Teobiefy.sessionKeyRequired();
      }
      if (service.config.strictPayload) {
        // The client holds a key and still sent clear data.
        Log.warning('Teobiefy: a clear body from a client with a session.');
        return Teobiefy.invalidPayload();
      }
    }

    final response = await next(request);
    if (request.attributes[Teobiefy.handshakeAttribute] == true) {
      // The client has no key before its handshake.
      return response;
    }
    return _encrypt(response, () => keyFor((keys) => keys.tx), service);
  }

  static Future<Response> _encrypt(
    Response response,
    Future<Uint8List?> Function() keyFor,
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
    final key = await keyFor();
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
