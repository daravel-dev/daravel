# Google

`daravel_google` connects an application to Google: users sign in to their
Google account and let the application use their calendar (OAuth 2.0), or
the application acts on its own through a service account; then it creates
Google Calendar events with guests and Google Meet links. User tokens are
stored in the JSON google/apiclient stores, so a Laravel application and a
Daravel one can keep them in the same column and refresh them in turn.

```bash
dart pub add daravel_google
```

```dart
// bootstrap/app.dart
import 'package:daravel_google/daravel_google.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withGoogle()
    // ...
    .create();
```

```dotenv
# OAuth, for users' calendars (the names Socialite uses)
GOOGLE_CLIENT_ID=....apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=...
GOOGLE_REDIRECT_URI=https://app.example.com/google/callback

# A service account, for the application's own calendar (Google's name)
GOOGLE_APPLICATION_CREDENTIALS=storage/app/google/service-account.json
GOOGLE_CALENDAR_ID=kelas@group.calendar.google.com      # as spatie/laravel-google-calendar
GOOGLE_CALENDAR_IMPERSONATE=admin@sekolah.sch.id         # optional, domain-wide delegation
```

Event times given as wall clock times are in `APP_TIMEZONE`. Boot warns
when `GOOGLE_APPLICATION_CREDENTIALS` names a file that does not exist.

## Users' calendars

A user gives the application access once, on Google's consent page:

```dart
router.get('/google/connect', (request) {
  final state = Str.random(40);
  // Keep `state` (in the user's record or a signed cookie) to check it on return.
  return Response.redirect(
    Google.oauth
        .authorizationUrl(
          scopes: [GoogleScopes.openid, GoogleScopes.email, GoogleScopes.calendar],
          state: state,
        )
        .toString(),
  );
});

router.get('/google/callback', (request) async {
  // Check request.query['state'] against the one you kept first.
  final token = await Google.oauth.exchangeCode(request.query['code']!);
  final user = (await Auth.user<User>())!;
  user.googleCred = token.encode(); // google/apiclient's JSON
  await user.save();
  return Response.redirect('/meetings');
});
```

`authorizationUrl` asks for offline access with `prompt=consent`, so the
first exchange returns a refresh token. `GoogleToken` reads and writes the
token as google/apiclient does (`access_token`, `expires_in`, `created`,
`refresh_token`, `scope`). `Google.calendarFor` refreshes it a minute
before it expires and hands each new token to `onRefresh` to store:

```dart
final user = (await Auth.user<User>())!;
final token = GoogleToken.parse(user.googleCred!);
if (!token.hasScope(GoogleScopes.calendar)) {
  return Response.json({'message': 'Connect Google Calendar first.'}, status: 409);
}
final calendar = Google.calendarFor(token, onRefresh: (fresh) async {
  user.googleCred = fresh.encode();
  await user.save();
});
```

Requests that need a refresh at the same time share one. A refresh token
the user revoked fails with a `GoogleException` whose `reason` is
`invalid_grant`: ask the user to connect again. `Google.oauth.revoke(token)`
disconnects.

## Service accounts

A service account is the application's own Google identity: no user signs
in. It writes to calendars shared with its email address or, in Google
Workspace with domain-wide delegation, to a user's calendar as that user
(`GOOGLE_CALENDAR_IMPERSONATE`, or `subject:`):

```dart
final calendar = Google.serviceCalendar(); // GOOGLE_CALENDAR_ID
final asTeacher = Google.serviceCalendar(subject: 'guru@sekolah.sch.id');
```

The access token comes from a JWT signed with the key file's RSA key
(RS256, RFC 7523), fetched when first needed and again a minute before it
expires. The credentials are held per isolate, by scopes and subject
(`Google.serviceCredentials`), so every `serviceCalendar()` call shares
one token; each worker isolate fetches its own, like a PHP-FPM worker's
APCu cache. `GoogleServiceAccount.fromFile(path)` works without the facade.

## Events

```dart
final event = await calendar.create(
  CalendarEvent(
    summary: meeting.name,
    description: meeting.description,
    start: EventTime(DateTime(2026, 10, 28, 7, 30)),   // 07:30 in APP_TIMEZONE
    end: EventTime(DateTime(2026, 10, 28, 9)),
    attendees: [
      for (final student in students)
        EventAttendee(student.email, displayName: student.name),
    ],
    meet: true,                                        // a new Google Meet link
  ),
);
meeting.calendarEventId = event.id;
meeting.meetUrl = event.meetUrl;
```

Google emails the guests (`sendUpdates: SendUpdates.all`, the default; also
`externalOnly` and `none`). A `DateTime` in UTC is an instant; any other is
a wall clock time in the event's `timeZone` or the calendar's
(`APP_TIMEZONE`); `EventTime.date(day)` is an all-day event.

| Call | Does |
| :-- | :-- |
| `create(event)` | adds the event; `meet: true` creates a Meet link |
| `get(id)` | one event |
| `list(from:, to:, query:)` | the events in a period, each occurrence of a recurring one, in order of start, every page |
| `patch(id, changes)` | changes only the fields set; the guests and the Meet link stay unless set |
| `replace(id, event)` | replaces the whole event (PUT): what is left out is cleared |
| `delete(id)` | deletes it; one already deleted is fine |

Errors are `GoogleException`s with Google's `status` and `reason`
(`notFound`, `insufficientPermissions`, `rateLimitExceeded`, ...).

## With Laravel

- **Tokens.** google/apiclient's `getAccessToken()` array and
  `GoogleToken.toJson()` are the same JSON, so a `google_cred` column
  written by either application is read and refreshed by the other.
- **Updates.** google/apiclient's `$calendar->events->update(...)` is a PUT:
  a Laravel action that rebuilds the event on every update and asks for a
  conference again gets a new Meet link each time. `patch` changes only
  what you set; `replace` is the PUT, for parity.
- **Settings.** `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and
  `GOOGLE_REDIRECT_URI` are Socialite's names, `GOOGLE_CALENDAR_ID` and
  `GOOGLE_CALENDAR_IMPERSONATE` spatie/laravel-google-calendar's.

The RS256 signature of service account tokens is checked in the tests
against the public key, and was compared byte for byte with OpenSSL's for
the same key and input.
