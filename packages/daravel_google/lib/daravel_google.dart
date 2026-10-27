/// Google for Daravel: OAuth 2.0 user tokens that refresh themselves (in
/// google/apiclient's JSON, so a Laravel application can share them),
/// service accounts (RS256 JWT, RFC 7523) and Google Calendar v3 with
/// guests and Google Meet links.
///
/// ```dart
/// Application.configure(basePath: '.').withGoogle()
/// ```
library;

export 'src/calendar.dart';
export 'src/client.dart' show GoogleException;
export 'src/credentials.dart';
export 'src/oauth.dart';
export 'src/service_account.dart';
export 'src/setup.dart';
export 'src/token.dart';
