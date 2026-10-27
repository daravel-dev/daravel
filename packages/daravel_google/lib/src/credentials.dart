import 'dart:async';

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

  /// The current token (the refreshed one after a refresh).
  GoogleToken get token => _token;

  @override
  Future<String> accessToken() async {
    if (!_token.expired()) {
      return _token.accessToken;
    }
    final refreshing = _refreshing ??= () async {
      try {
        final fresh = await oauth.refresh(_token);
        _token = fresh;
        await onRefresh?.call(fresh);
        return fresh;
      } finally {
        _refreshing = null;
      }
    }();
    return (await refreshing).accessToken;
  }
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
