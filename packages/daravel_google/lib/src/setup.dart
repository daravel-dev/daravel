import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';

import 'calendar.dart';
import 'credentials.dart';
import 'oauth.dart';
import 'service_account.dart';
import 'token.dart';

/// Google settings from `.env`, under Laravel's and Google's names:
/// `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `GOOGLE_REDIRECT_URI`
/// (OAuth, as Socialite names them), `GOOGLE_APPLICATION_CREDENTIALS` (a
/// service account key file, Google's own name), and `GOOGLE_CALENDAR_ID`
/// and `GOOGLE_CALENDAR_IMPERSONATE` (as spatie/laravel-google-calendar).
final class GoogleConfig implements ConfigSection {
  const GoogleConfig({
    this.clientId = '',
    this.clientSecret = '',
    this.redirectUri,
    this.credentials,
    this.calendarId = 'primary',
    this.impersonate,
    this.timeZone = 'UTC',
  });

  factory GoogleConfig.fromEnv(Env env) => GoogleConfig(
    clientId: env.string('GOOGLE_CLIENT_ID', ''),
    clientSecret: env.string('GOOGLE_CLIENT_SECRET', ''),
    redirectUri: env.maybeString('GOOGLE_REDIRECT_URI'),
    credentials: env.maybeString('GOOGLE_APPLICATION_CREDENTIALS'),
    calendarId: env.string('GOOGLE_CALENDAR_ID', 'primary'),
    impersonate: env.maybeString('GOOGLE_CALENDAR_IMPERSONATE'),
    timeZone: env.string('APP_TIMEZONE', 'UTC'),
  );

  final String clientId;
  final String clientSecret;
  final String? redirectUri;

  /// The path of a service account's JSON key.
  final String? credentials;

  /// The calendar [Google.calendar] uses.
  final String calendarId;

  /// The Workspace user a service account acts as (domain-wide delegation).
  final String? impersonate;

  /// Of wall clock event times (`APP_TIMEZONE`).
  final String timeZone;

  /// Warns when the service account key file named does not exist.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final path = config.section<GoogleConfig>().credentials;
    return [
      if (path != null && !File(path).existsSync())
        ConfigIssue(
          ConfigIssueLevel.warning,
          'Google: GOOGLE_APPLICATION_CREDENTIALS names $path, which does '
          'not exist.',
        ),
    ];
  }

  @override
  String get key => 'google';

  @override
  Map<String, Object?> toMap() => {
    'client_id': clientId,
    'client_secret': clientSecret.isEmpty ? '' : '********',
    'redirect_uri': redirectUri,
    'credentials': credentials,
    'calendar_id': calendarId,
    'impersonate': impersonate,
    'time_zone': timeZone,
  };
}

/// `withGoogle()` on the application builder.
extension GoogleApplicationBuilder on ApplicationBuilder {
  /// Adds Google: [GoogleConfig] from `.env` and the [Google] facade, whose
  /// clients send through the application's HTTP client.
  ApplicationBuilder withGoogle() =>
      withConfig<GoogleConfig>(GoogleConfig.fromEnv)
          .withConfigCheck(GoogleConfig.check)
          .withBindings(
            (container) => container
              ..singleton<GoogleOAuth>((c) {
                final config = c
                    .make<ConfigRepository>()
                    .section<GoogleConfig>();
                return GoogleOAuth(
                  clientId: config.clientId,
                  clientSecret: config.clientSecret,
                  redirectUri: config.redirectUri,
                  http: c.make<HttpClientFactory>(),
                );
              })
              ..singleton<GoogleServiceAccount>((c) {
                final config = c
                    .make<ConfigRepository>()
                    .section<GoogleConfig>();
                final path = config.credentials;
                if (path == null) {
                  throw const ConfigException(
                    'Google: set GOOGLE_APPLICATION_CREDENTIALS to a service '
                    'account key file.',
                  );
                }
                return GoogleServiceAccount.fromFile(
                  path,
                  http: c.make<HttpClientFactory>(),
                );
              }),
          );
}

/// Google from anywhere in a request, job or command.
abstract final class Google {
  static GoogleConfig get config =>
      Container.current.make<ConfigRepository>().section<GoogleConfig>();

  /// OAuth with `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and
  /// `GOOGLE_REDIRECT_URI`.
  static GoogleOAuth get oauth => Container.current.make<GoogleOAuth>();

  /// The service account of `GOOGLE_APPLICATION_CREDENTIALS`.
  static GoogleServiceAccount get serviceAccount =>
      Container.current.make<GoogleServiceAccount>();

  /// A calendar with [credentials] ([calendarId] defaults to
  /// `GOOGLE_CALENDAR_ID`, wall clock times are in `APP_TIMEZONE`).
  static GoogleCalendar calendar(
    GoogleCredentials credentials, {
    String? calendarId,
  }) {
    final config = Google.config;
    return GoogleCalendar(
      credentials,
      calendarId: calendarId ?? config.calendarId,
      timeZone: config.timeZone,
      http: Container.current.make<HttpClientFactory>(),
    );
  }

  /// A user's calendar with their stored [token], refreshed when needed;
  /// [onRefresh] receives each new token to store ([GoogleToken.encode]).
  static GoogleCalendar calendarFor(
    GoogleToken token, {
    FutureOr<void> Function(GoogleToken token)? onRefresh,
    String calendarId = 'primary',
  }) => calendar(
    UserCredentials(token, oauth: oauth, onRefresh: onRefresh),
    calendarId: calendarId,
  );

  /// The calendar of `GOOGLE_CALENDAR_ID` as the service account, acting
  /// as [subject] (default `GOOGLE_CALENDAR_IMPERSONATE`) when set.
  static GoogleCalendar serviceCalendar({
    String? subject,
    String? calendarId,
  }) => calendar(
    ServiceAccountCredentials(
      serviceAccount,
      scopes: const [GoogleScopes.calendar],
      subject: subject ?? config.impersonate,
    ),
    calendarId: calendarId,
  );
}
