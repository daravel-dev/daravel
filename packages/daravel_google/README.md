<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_google

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_google/README.id.md)

Google for [Daravel](https://pub.dev/packages/daravel): OAuth 2.0 user
tokens that refresh themselves, service accounts (RS256 JWT, RFC 7523) and
Google Calendar v3 with guests and Google Meet links. Tokens are stored in
google/apiclient's JSON, so a Laravel and a Daravel application can share
them.

```bash
dart pub add daravel_google
```

```dart
Application.configure(basePath: '.').withGoogle() // GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, ...

// A user's calendar, with the token stored at sign-in (refreshed when needed).
final calendar = Google.calendarFor(
  GoogleToken.parse(user.googleCred!),
  onRefresh: (fresh) async {
    user.googleCred = fresh.encode();
    await user.save();
  },
);

final event = await calendar.create(CalendarEvent(
  summary: 'Matematika XI',
  start: EventTime(DateTime(2026, 10, 28, 7, 30)), // in APP_TIMEZONE
  end: EventTime(DateTime(2026, 10, 28, 9)),
  attendees: [EventAttendee('siswa@sekolah.sch.id', displayName: 'Siswa')],
  meet: true,
));
print(event.meetUrl);
```

- `GoogleOAuth`: the consent URL (offline access), the code exchange,
  refresh and revoke; concurrent refreshes share one.
- `GoogleServiceAccount`: the key file, an RS256 assertion (checked
  byte for byte against OpenSSL), domain-wide delegation with `subject`.
- `GoogleCalendar`: create, get, list (every page), patch, replace and
  delete events; `GoogleException` carries Google's `status` and `reason`.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/google.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart", "Google",
"Google Calendar" and "Google Meet" are trademarks of Google LLC. Daravel
is an independent project, not affiliated with or endorsed by any of them.
