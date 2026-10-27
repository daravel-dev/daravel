import 'dart:convert';

import 'package:daravel/daravel.dart';

/// An OAuth 2.0 access token, stored as google/apiclient stores it
/// (`Google_Client::getAccessToken()`): `access_token`, `expires_in`,
/// `created` (Unix seconds), `refresh_token`, `scope` (space-separated),
/// `token_type` and `id_token`. A Laravel application and a Daravel one
/// can therefore keep the same JSON in the same column (for example a
/// `google_cred` column of `users`) and refresh it in turn.
final class GoogleToken {
  const GoogleToken({
    required this.accessToken,
    required this.created,
    required this.expiresIn,
    this.refreshToken,
    this.scopes = const [],
    this.tokenType = 'Bearer',
    this.idToken,
  });

  /// google/apiclient's token array (see the class comment).
  factory GoogleToken.fromJson(Map<String, Object?> json) => GoogleToken(
    accessToken: json['access_token']! as String,
    created: DateTime.fromMillisecondsSinceEpoch(
      ((json['created'] as num?) ?? 0).toInt() * 1000,
      isUtc: true,
    ),
    expiresIn: Duration(seconds: ((json['expires_in'] as num?) ?? 0).toInt()),
    refreshToken: _nonEmpty(json['refresh_token']),
    scopes: _scopes(json['scope']),
    tokenType: (json['token_type'] as String?) ?? 'Bearer',
    idToken: _nonEmpty(json['id_token']),
  );

  /// The answer of Google's token endpoint, received now ([Clock.now]).
  factory GoogleToken.fromResponse(Map<String, Object?> json) =>
      GoogleToken.fromJson({
        ...json,
        'created': Clock.now().millisecondsSinceEpoch ~/ 1000,
      });

  /// [GoogleToken.fromJson] of a JSON string, such as a stored column.
  factory GoogleToken.parse(String json) =>
      GoogleToken.fromJson(jsonDecode(json) as Map<String, Object?>);

  final String accessToken;

  /// When the token was issued.
  final DateTime created;

  /// How long it is valid from [created].
  final Duration expiresIn;

  /// Present when the user granted offline access.
  final String? refreshToken;
  final List<String> scopes;
  final String tokenType;
  final String? idToken;

  DateTime get expiresAt => created.add(expiresIn);

  /// Whether the token is expired, or expires within [leeway] ([Clock.now]).
  bool expired({Duration leeway = const Duration(minutes: 1)}) =>
      !Clock.now().isBefore(expiresAt.subtract(leeway));

  /// Whether [scope] was granted (`https://www.googleapis.com/auth/calendar`).
  bool hasScope(String scope) => scopes.contains(scope);

  /// [fresh], a refreshed token, keeping this refresh token when Google did
  /// not send a new one (it usually does not).
  GoogleToken renewedBy(GoogleToken fresh) => fresh.refreshToken != null
      ? fresh
      : GoogleToken(
          accessToken: fresh.accessToken,
          created: fresh.created,
          expiresIn: fresh.expiresIn,
          refreshToken: refreshToken,
          scopes: fresh.scopes.isEmpty ? scopes : fresh.scopes,
          tokenType: fresh.tokenType,
          idToken: fresh.idToken ?? idToken,
        );

  /// google/apiclient's token array.
  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'expires_in': expiresIn.inSeconds,
    'created': created.millisecondsSinceEpoch ~/ 1000,
    'refresh_token': ?refreshToken,
    'scope': scopes.join(' '),
    'token_type': tokenType,
    'id_token': ?idToken,
  };

  /// [toJson] as a string, to store.
  String encode() => jsonEncode(toJson());

  static String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static List<String> _scopes(Object? value) => switch (value) {
    final String text => [
      for (final scope in text.split(' '))
        if (scope.isNotEmpty) scope,
    ],
    final List<Object?> list => [for (final scope in list) '$scope'],
    _ => const [],
  };
}
