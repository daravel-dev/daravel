import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'crypto.dart';

/// The answer of a handshake: what the client keeps.
typedef TeobiefyHandshake = ({
  String sessionId,
  String serverPublicKey,
  int expiresIn,
});

/// Session keys of the v1 protocol (Bali Melajah's `SessionKeyService`):
/// a handshake derives a pair per client with X25519 (`crypto_kx`) and
/// keeps it in the cache under a random 64-hex session id, for [ttl] after
/// its last use. The id is not a credential: it only names the key pair.
final class TeobiefySessions {
  TeobiefySessions(
    this.cache, {
    this.ttl = const Duration(seconds: 1800),
    this.prefix = 'libsodium:session-key:',
  });

  /// The header that carries the session id.
  static const String header = 'X-Session-Id';

  static final RegExp _id = RegExp(r'^[a-f0-9]{64}$');
  static final Random _random = Random.secure();

  final CacheRepository cache;

  /// Sliding: each use keeps the session for this long again.
  final Duration ttl;
  final String prefix;

  /// The server's half of a handshake with [clientPublicKey] (base64 of 32
  /// bytes). [ArgumentError] when the key is not one.
  Future<TeobiefyHandshake> establish(String clientPublicKey) async {
    final client = TeobiefyCrypto.strictBase64(clientPublicKey);
    if (client == null || client.length != 32) {
      throw ArgumentError('Client public key tidak valid.');
    }
    final server = await TeobiefyCrypto.newKeyPair();
    final keys = await TeobiefyCrypto.serverSessionKeys(server, client);
    final sessionId = [for (var i = 0; i < 32; i++) _random.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // Base64, as the Laravel application stores them.
    await cache.put('$prefix$sessionId', {
      'rx': base64.encode(keys.rx),
      'tx': base64.encode(keys.tx),
    }, ttl: ttl);
    return (
      sessionId: sessionId,
      serverPublicKey: base64.encode((await server.extractPublicKey()).bytes),
      expiresIn: ttl.inSeconds,
    );
  }

  /// The keys of [sessionId], kept for [ttl] again, or null when it is not
  /// one of ours or has expired. An id that is not 64 hex digits never
  /// reaches the cache.
  Future<SessionKeys?> find(String? sessionId) async {
    if (sessionId == null || !_id.hasMatch(sessionId)) {
      return null;
    }
    final stored = await cache.get<Object?>('$prefix$sessionId');
    if (stored is! Map<Object?, Object?>) {
      return null;
    }
    final rx = TeobiefyCrypto.strictBase64(stored['rx']);
    final tx = TeobiefyCrypto.strictBase64(stored['tx']);
    if (rx == null || tx == null || rx.length != 32 || tx.length != 32) {
      return null;
    }
    await cache.put('$prefix$sessionId', stored, ttl: ttl);
    return (rx: rx, tx: tx);
  }

  /// Records that [nonce] was used by [sessionId] (`legacy` for the legacy
  /// key) and tells whether it was the first time. A client seals every
  /// request with a fresh random nonce, so a repeat is a captured body sent
  /// again; it is remembered for [ttl], after which the session itself is
  /// gone. The protocol carries no timestamp or sequence, so this is the
  /// replay check (the Laravel application has none).
  Future<bool> useNonce(String sessionId, List<int> nonce) =>
      cache.add('$prefix$sessionId:nonce:${base64.encode(nonce)}', 1, ttl: ttl);
}
