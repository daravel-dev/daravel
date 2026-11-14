import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'models.dart';
import 'token.dart';

/// A webhook that is not LiveKit's: no or a bad token, or a body other
/// than the one the token vouches for. Answered 401.
final class LivekitWebhookException extends HttpException {
  /// A webhook whose signature is missing or wrong (401).
  const LivekitWebhookException(String message) : super(401, message);
}

/// An event LiveKit posted (`room_started`, `room_finished`,
/// `participant_joined`, `participant_left`, `track_published`,
/// `egress_ended`, ...).
final class LivekitWebhookEvent {
  /// An event from the webhook's [json].
  LivekitWebhookEvent(this.json);

  /// The raw JSON.
  final Map<String, Object?> json;

  /// The event name (`room_started`, `participant_joined`...).
  String get event => stringField(json, 'event');

  /// The event id.
  String get id => stringField(json, 'id');

  /// When the event happened; null when absent, 0, or past what a
  /// [DateTime] holds.
  DateTime? get createdAt => switch (intField(json, 'created_at')) {
    final int seconds when seconds > 0 && seconds <= _maxSeconds =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    _ => null,
  };

  /// The latest second a [DateTime] holds.
  static const int _maxSeconds = 8640000000000;

  /// The room, for room and participant events.
  LivekitRoom? get room => switch (field(json, 'room')) {
    final Map<String, Object?> room => LivekitRoom(room),
    _ => null,
  };

  /// The participant, for participant events.
  LivekitParticipant? get participant => switch (field(json, 'participant')) {
    final Map<String, Object?> participant => LivekitParticipant(participant),
    _ => null,
  };

  /// The track, egress or ingress the event is about, as LiveKit sent it.
  Map<String, Object?>? get track => _object('track');

  /// The egress details, for egress events.
  Map<String, Object?>? get egressInfo => _object('egress_info');

  /// The ingress details, for ingress events.
  Map<String, Object?>? get ingressInfo => _object('ingress_info');

  /// The object [name]; [LivekitWebhookException] when it is another type.
  Map<String, Object?>? _object(String name) => switch (field(json, name)) {
    null => null,
    final Map<String, Object?> object => object,
    _ => throw LivekitWebhookException('The webhook $name is not an object.'),
  };

  @override
  String toString() => 'LivekitWebhookEvent($event)';
}

/// Verifies LiveKit's webhooks as its SDKs do: the `Authorization` header
/// is a token LiveKit signed with the API secret and issued under the API
/// key, still valid, whose `sha256` claim is the base64 SHA-256 of the
/// exact body. Anything else throws [LivekitWebhookException].
final class LivekitWebhookReceiver {
  /// Verifies webhooks signed with [apiKey] and [apiSecret].
  const LivekitWebhookReceiver({
    required this.apiKey,
    required this.apiSecret,
    this.maxAge = const Duration(minutes: 5),
  });

  /// The API key expected.
  final String apiKey;

  /// The API secret verifying signatures.
  final String apiSecret;

  /// How old an event may be (`created_at` against `Clock.now()`, with
  /// 30 s of skew either way): a captured webhook can be replayed for as
  /// long as its token is valid, and LiveKit signs tokens for minutes, so
  /// this closes the window at five minutes. While it is set, an event
  /// without an id or a readable `created_at` is refused. `null` only
  /// checks the token. LiveKit's server SDKs check the token and the body's
  /// checksum only; the age, the id and [Livekit.webhook]'s replay check
  /// are this package's.
  final Duration? maxAge;

  /// Clock skew tolerated when checking [maxAge].
  static const Duration skew = Duration(seconds: 30);

  /// How long an event is accepted for, from the first moment to the last:
  /// from [skew] before its `created_at` to [maxAge] plus [skew] after it.
  /// A replay check must remember an event at least this long.
  static Duration acceptance(Duration maxAge) => maxAge + skew * 2;

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
    LivekitToken.requireKey(apiKey);
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
    if (limit != null) {
      // The age and the replay checks need both; LiveKit sends both.
      if (event.id.isEmpty) {
        throw const LivekitWebhookException('The webhook has no id.');
      }
      if (createdAt == null) {
        throw LivekitWebhookException(
          'Webhook ${event.id} has no readable created_at.',
        );
      }
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
