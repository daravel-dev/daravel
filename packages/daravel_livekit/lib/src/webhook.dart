import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'models.dart';
import 'token.dart';

/// A webhook that is not LiveKit's: no or a bad token, or a body other
/// than the one the token vouches for. Answered 401.
final class LivekitWebhookException extends HttpException {
  const LivekitWebhookException(String message) : super(401, message);
}

/// An event LiveKit posted (`room_started`, `room_finished`,
/// `participant_joined`, `participant_left`, `track_published`,
/// `egress_ended`, ...).
final class LivekitWebhookEvent {
  LivekitWebhookEvent(this.json);

  final Map<String, Object?> json;

  String get event => stringField(json, 'event');
  String get id => stringField(json, 'id');

  DateTime? get createdAt => switch (intField(json, 'created_at')) {
    0 => null,
    final int seconds => DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    ),
  };

  LivekitRoom? get room => switch (field(json, 'room')) {
    final Map<String, Object?> room => LivekitRoom(room),
    _ => null,
  };

  LivekitParticipant? get participant => switch (field(json, 'participant')) {
    final Map<String, Object?> participant => LivekitParticipant(participant),
    _ => null,
  };

  /// The track, egress or ingress the event is about, as LiveKit sent it.
  Map<String, Object?>? get track =>
      field(json, 'track') as Map<String, Object?>?;
  Map<String, Object?>? get egressInfo =>
      field(json, 'egress_info') as Map<String, Object?>?;
  Map<String, Object?>? get ingressInfo =>
      field(json, 'ingress_info') as Map<String, Object?>?;

  @override
  String toString() => 'LivekitWebhookEvent($event)';
}

/// Verifies LiveKit's webhooks as its SDKs do: the `Authorization` header
/// is a token LiveKit signed with the API secret and issued under the API
/// key, still valid, whose `sha256` claim is the base64 SHA-256 of the
/// exact body. Anything else throws [LivekitWebhookException].
final class LivekitWebhookReceiver {
  const LivekitWebhookReceiver({
    required this.apiKey,
    required this.apiSecret,
    this.maxAge = const Duration(minutes: 5),
  });

  final String apiKey;
  final String apiSecret;

  /// How old an event may be (`created_at` against `Clock.now()`, with
  /// 30 s of skew either way): a captured webhook can be replayed for as
  /// long as its token is valid, and LiveKit signs tokens for minutes, so
  /// this closes the window at five minutes. `null` only checks the token.
  final Duration? maxAge;

  /// Clock skew tolerated when checking [maxAge].
  static const Duration skew = Duration(seconds: 30);

  /// [body] as it arrived, and the `Authorization` header (with or without
  /// `Bearer `).
  Future<LivekitWebhookEvent> receive(
    List<int> body,
    String? authorization,
  ) async {
    // Before the header is even looked at: with no secret there is nothing
    // to verify against, and the caller's error is a 500, not a 401 that
    // would be charged to LiveKit. (With an empty key, anyone who knows
    // the API key, the `iss` of every client token, could sign webhooks.)
    LivekitToken.requireSecret(apiSecret);
    final header = authorization?.trim() ?? '';
    if (header.isEmpty) {
      throw const LivekitWebhookException('Authorization header is empty.');
    }
    final jwt = header.toLowerCase().startsWith('bearer ')
        ? header.substring(7).trim()
        : header;
    final LivekitClaims claims;
    try {
      claims = await LivekitToken.verify(
        jwt,
        apiKey: apiKey,
        apiSecret: apiSecret,
      );
    } on JwtException catch (error) {
      throw LivekitWebhookException('Invalid webhook token: ${error.message}');
    }
    final expected = base64.encode(sha256.convert(body).bytes);
    if (!_same(claims.sha256 ?? '', expected)) {
      throw const LivekitWebhookException(
        'Sha256 checksum of the body does not match.',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw const LivekitWebhookException('The body is not JSON.');
    }
    if (json is! Map<String, Object?>) {
      throw const LivekitWebhookException('The body is not a JSON object.');
    }
    final event = LivekitWebhookEvent(json);
    final limit = maxAge;
    final createdAt = event.createdAt;
    if (limit != null && createdAt != null) {
      final age = Clock.now().toUtc().difference(createdAt);
      if (age > limit + skew) {
        throw LivekitWebhookException(
          'Webhook ${event.id} is ${age.inSeconds}s old; events older '
          'than ${limit.inSeconds}s are refused (a replay?).',
        );
      }
      if (age < -skew) {
        throw LivekitWebhookException(
          'Webhook ${event.id} is dated ${(-age).inSeconds}s in the '
          'future.',
        );
      }
    }
    return event;
  }

  /// The webhook of [request] (its raw body and `Authorization` header).
  Future<LivekitWebhookEvent> fromRequest(Request request) async =>
      receive(await request.bytes(), request.header('authorization'));

  /// Constant-time comparison, so the checksum cannot be guessed byte by
  /// byte.
  static bool _same(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
