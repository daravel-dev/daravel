<!-- source: README.md sha256:d3d90243bb04 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_google

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_google/README.md) · Bahasa Indonesia

Google untuk [Daravel](https://pub.dev/packages/daravel): token user OAuth
2.0 yang me-refresh dirinya sendiri, service account (JWT RS256, RFC 7523),
dan Google Calendar v3 dengan tamu serta link Google Meet. Token disimpan
dalam JSON google/apiclient, sehingga aplikasi Laravel dan aplikasi Daravel
bisa memakainya bersama.

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

- `GoogleOAuth`: URL persetujuan (akses offline), pertukaran code, refresh,
  dan revoke; refresh yang bersamaan berbagi satu.
- `GoogleServiceAccount`: file kunci, assertion RS256 (dicek byte demi byte
  dengan OpenSSL), domain-wide delegation lewat `subject`.
- `GoogleCalendar`: create, get, list (semua halaman), patch, replace, dan
  delete event; `GoogleException` membawa `status` dan `reason` dari Google.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/google.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart", "Google",
"Google Calendar", dan "Google Meet" adalah merek dagang Google LLC. Daravel
adalah proyek independen, tidak berafiliasi dengan atau didukung oleh
mereka.
