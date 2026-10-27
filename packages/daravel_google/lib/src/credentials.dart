import 'dart:async';

import 'client.dart';
import 'oauth.dart';
import 'service_account.dart';
import 'token.dart';

/// Where a Google client gets its access token.
abstract interface class GoogleCredentials {
  /// A plain access token, used as it is (a caller that refreshes on its
  /// own, as google/apiclient's middleware does in Laravel).
  const factory GoogleCredentials.token(String accessToken) = _StaticToken;

  /// A valid access token, refreshed first when needed.
  Future<String> accessToken();
}

final class _StaticToken implements GoogleCredentials {
  const _StaticToken(this._token);

  final String _token;

  @override
  Future<String> accessToken() async => _token;
}

/// A user's token, refreshed with [oauth] a minute before it expires.
/// [onRefresh] receives each new token, to store it (in google/apiclient's
/// JSON: [GoogleToken.encode]); calls at the same time share one refresh.
final class UserCredentials implements GoogleCredentials {
  UserCredentials(this._token, {required this.oauth, this.onRefresh});

  GoogleToken _token;
  final GoogleOAuth oauth;
  final FutureOr<void> Function(GoogleToken token)? onRefresh;
  Future<GoogleToken>? _refreshing;
  GoogleException? _revoked;

  /// The current token (the refreshed one after a refresh).
  GoogleToken get token => _token;

  /// Set once Google answered `invalid_grant`: the refresh token is
  /// revoked or expired, the user must consent again, and asking Google
  /// again on every call would only hammer its token endpoint. Cleared by
  /// [replace].
  GoogleException? get revoked => _revoked;

  /// Uses [token] from now on (after the user consented again).
  void replace(GoogleToken token) {
    _token = token;
    _revoked = null;
  }

  @override
  Future<String> accessToken() async {
    if (!_token.expired()) {
      return _token.accessToken;
    }
    if (_revoked case final GoogleException error) {
      throw error;
    }
    final refreshing = _refreshing ??= () async {
      try {
        final GoogleToken fresh;
        try {
          fresh = await oauth.refresh(_token);
        } on GoogleException catch (error) {
          if (error.reason == 'invalid_grant') {
            _revoked = error;
          }
          rethrow;
        }
        // Stored first: if the store fails, the token in memory stays the
        // old one, so the next call refreshes and stores again instead of
        // serving a token the database never saw (and, had Google rotated
        // the refresh token, one the next process could not refresh).
        await onRefresh?.call(fresh);
        _token = fresh;
        return fresh;
      } finally {
        _refreshing = null;
      }
    }();
    return (await refreshing).accessToken;
  }
}

/// The [ServiceAccountCredentials] of this isolate by scopes and subject,
/// so repeated `Google.serviceCalendar()` calls share one token (and one
/// in-flight fetch) instead of signing an assertion and calling Google's
/// token endpoint each. Per isolate: worker isolates share no memory, so
/// each holds its own token, like a PHP-FPM worker's APCu cache.
final class ServiceAccountCredentialsCache {
  ServiceAccountCredentialsCache(this.account);

  final GoogleServiceAccount account;
  final Map<String, ServiceAccountCredentials> _credentials = {};

  /// Credentials held for this isolate.
  int get size => _credentials.length;

  ServiceAccountCredentials of({
    required List<String> scopes,
    String? subject,
  }) => _credentials.putIfAbsent(
    '${subject ?? ''}|${(List.of(scopes)..sort()).join(' ')}',
    () => ServiceAccountCredentials(account, scopes: scopes, subject: subject),
  );
}

/// A service account's token for [scopes] (acting as [subject] when
/// given), fetched when first needed and again a minute before it expires;
/// calls at the same time share one fetch.
final class ServiceAccountCredentials implements GoogleCredentials {
  ServiceAccountCredentials(this.account, {required this.scopes, this.subject});

  final GoogleServiceAccount account;
  final List<String> scopes;
  final String? subject;
  GoogleToken? _token;
  Future<GoogleToken>? _fetching;

  @override
  Future<String> accessToken() async {
    final current = _token;
    if (current != null && !current.expired()) {
      return current.accessToken;
    }
    final fetching = _fetching ??= () async {
      try {
        return _token = await account.token(scopes: scopes, subject: subject);
      } finally {
        _fetching = null;
      }
    }();
    return (await fetching).accessToken;
  }
}
