import 'package:daravel/daravel.dart';

import 'client.dart';
import 'token.dart';

/// Google's OAuth 2.0 for web server applications (RFC 6749): the consent
/// URL, the code exchange, refreshing and revoking.
///
/// ```dart
/// final oauth = GoogleOAuth(clientId: id, clientSecret: secret,
///     redirectUri: 'https://app.test/google/callback');
/// final url = oauth.authorizationUrl(scopes: [GoogleScopes.calendar],
///     state: csrf);
/// // ... Google redirects back with ?code=
/// final token = await oauth.exchangeCode(code); // store token.encode()
/// ```
final class GoogleOAuth {
  GoogleOAuth({
    required this.clientId,
    required this.clientSecret,
    this.redirectUri,
    HttpClientFactory? http,
    this.timeout = const Duration(seconds: 10),
  }) : _http = GoogleHttp(http);

  final String clientId;
  final String clientSecret;
  final String? redirectUri;
  final Duration timeout;
  final GoogleHttp _http;

  static const String authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const String revocationEndpoint =
      'https://oauth2.googleapis.com/revoke';

  /// The consent page to send the user to. `access_type=offline` and
  /// `prompt=consent` (the defaults) return a refresh token, as
  /// google/apiclient's `setAccessType('offline')` and
  /// `setApprovalPrompt('force')` do. Pass a random [state] and check it
  /// on the callback.
  Uri authorizationUrl({
    required List<String> scopes,
    String? state,
    bool offline = true,
    String? prompt = 'consent',
    bool includeGrantedScopes = true,
    String? loginHint,
    String? codeChallenge,
  }) => Uri.parse(authorizationEndpoint).replace(
    queryParameters: {
      'client_id': clientId,
      'redirect_uri': ?redirectUri,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'state': ?state,
      if (offline) 'access_type': 'offline',
      'prompt': ?prompt,
      if (includeGrantedScopes) 'include_granted_scopes': 'true',
      'login_hint': ?loginHint,
      if (codeChallenge != null) ...{
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      },
    },
  );

  /// Exchanges the authorization [code] of the callback for a token.
  Future<GoogleToken> exchangeCode(String code, {String? codeVerifier}) =>
      _token('Exchange the authorization code', {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': ?redirectUri,
        'code_verifier': ?codeVerifier,
      });

  /// A new access token for [token], keeping its refresh token when Google
  /// does not send a new one. [GoogleException] with reason `invalid_grant`
  /// when the user revoked access or the refresh token expired.
  Future<GoogleToken> refresh(GoogleToken token) async {
    final refreshToken = token.refreshToken;
    if (refreshToken == null) {
      throw const GoogleException(
        'Refresh the access token: it has no refresh token (ask for offline '
        'access)',
        status: 0,
        reason: 'no_refresh_token',
      );
    }
    final fresh = await _token('Refresh the access token', {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    });
    return token.renewedBy(fresh);
  }

  /// Revokes [token] (its refresh token when it has one, which also ends
  /// its access tokens).
  Future<void> revoke(GoogleToken token) async {
    final response = await _http.factory
        .request()
        .timeout(timeout)
        .post(
          revocationEndpoint,
          form: {'token': token.refreshToken ?? token.accessToken},
        );
    if (!response.successful) {
      throw GoogleException.from('Revoke the token', response);
    }
  }

  Future<GoogleToken> _token(String action, Map<String, String> form) async {
    final response = await _http.factory
        .request()
        .acceptJson()
        .timeout(timeout)
        .post(
          tokenEndpoint,
          form: {...form, 'client_id': clientId, 'client_secret': clientSecret},
        );
    if (!response.successful) {
      throw GoogleException.from(action, response);
    }
    return GoogleToken.fromResponse(response.jsonMap());
  }
}

/// Scopes the clients of this package use.
abstract final class GoogleScopes {
  /// Read and write every calendar of the user.
  static const String calendar = 'https://www.googleapis.com/auth/calendar';

  /// Events only, on calendars the user can edit.
  static const String calendarEvents =
      'https://www.googleapis.com/auth/calendar.events';

  static const String calendarReadonly =
      'https://www.googleapis.com/auth/calendar.readonly';
  static const String openid = 'openid';
  static const String email = 'https://www.googleapis.com/auth/userinfo.email';
  static const String profile =
      'https://www.googleapis.com/auth/userinfo.profile';
}
