<!-- source: google.md sha256:9b7f4bfdb1b0 -->
# Google

`daravel_google` menghubungkan aplikasi dengan Google: user masuk ke akun
Google-nya dan mengizinkan aplikasi memakai kalendernya (OAuth 2.0), atau
aplikasi bertindak atas namanya sendiri lewat service account; lalu aplikasi
membuat event Google Calendar dengan tamu dan link Google Meet. Token user
disimpan dalam JSON yang sama dengan yang disimpan google/apiclient, sehingga
aplikasi Laravel dan aplikasi Daravel bisa menyimpannya di kolom yang sama
dan me-refresh-nya bergantian.

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

Waktu event yang diberikan sebagai jam dinding memakai `APP_TIMEZONE`. Saat
boot muncul warning bila `GOOGLE_APPLICATION_CREDENTIALS` menunjuk file yang
tidak ada.

## Kalender user

User memberi akses ke aplikasi sekali saja, di halaman persetujuan Google:

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

`authorizationUrl` meminta akses offline dengan `prompt=consent`, sehingga
pertukaran pertama mengembalikan refresh token. `GoogleToken` membaca dan
menulis token seperti google/apiclient (`access_token`, `expires_in`,
`created`, `refresh_token`, `scope`). `Google.calendarFor` me-refresh-nya
satu menit sebelum kedaluwarsa dan menyerahkan setiap token baru ke
`onRefresh` untuk disimpan:

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

Request yang butuh refresh pada saat bersamaan berbagi satu refresh. Refresh
token yang sudah dicabut user gagal dengan `GoogleException` yang `reason`-nya
`invalid_grant`: minta user menghubungkan ulang. `Google.oauth.revoke(token)`
memutus koneksi.

## Service account

Service account adalah identitas Google aplikasi itu sendiri: tidak ada
user yang masuk. Service account menulis ke kalender yang dibagikan ke alamat
emailnya, atau, di Google Workspace dengan domain-wide delegation, ke
kalender seorang user sebagai user tersebut (`GOOGLE_CALENDAR_IMPERSONATE`,
atau `subject:`):

```dart
final calendar = Google.serviceCalendar(); // GOOGLE_CALENDAR_ID
final asTeacher = Google.serviceCalendar(subject: 'guru@sekolah.sch.id');
```

Access token-nya didapat dari JWT yang ditandatangani dengan kunci RSA di
file kunci (RS256, RFC 7523), diambil saat pertama kali dibutuhkan dan lagi
satu menit sebelum kedaluwarsa. `GoogleServiceAccount.fromFile(path)` bisa
dipakai tanpa facade.

## Event

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

Google mengirim email ke para tamu (`sendUpdates: SendUpdates.all`, default;
ada juga `externalOnly` dan `none`). `DateTime` dalam UTC adalah sebuah
instan; selain itu adalah jam dinding di `timeZone` event atau kalender
(`APP_TIMEZONE`); `EventTime.date(day)` adalah event sehari penuh.

| Pemanggilan | Fungsinya |
| :-- | :-- |
| `create(event)` | menambahkan event; `meet: true` membuat link Meet |
| `get(id)` | satu event |
| `list(from:, to:, query:)` | event dalam suatu periode, setiap kemunculan event berulang, urut menurut waktu mulai, semua halaman |
| `patch(id, changes)` | hanya mengubah field yang di-set; tamu dan link Meet tetap kecuali di-set |
| `replace(id, event)` | mengganti seluruh event (PUT): yang tidak diisi akan dikosongkan |
| `delete(id)` | menghapusnya; event yang sudah terhapus tidak masalah |

Error berupa `GoogleException` dengan `status` dan `reason` dari Google
(`notFound`, `insufficientPermissions`, `rateLimitExceeded`, ...).

## Bersama Laravel

- **Token.** Array `getAccessToken()` dari google/apiclient dan
  `GoogleToken.toJson()` adalah JSON yang sama, sehingga kolom `google_cred`
  yang ditulis salah satu aplikasi bisa dibaca dan di-refresh oleh aplikasi
  lainnya.
- **Update.** `$calendar->events->update(...)` dari google/apiclient adalah
  PUT: action Laravel yang membangun ulang event di setiap update dan meminta
  konferensi lagi akan mendapat link Meet baru setiap kali. `patch` hanya
  mengubah yang Anda set; `replace` adalah PUT-nya, untuk paritas.
- **Pengaturan.** `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, dan
  `GOOGLE_REDIRECT_URI` adalah nama dari Socialite; `GOOGLE_CALENDAR_ID` dan
  `GOOGLE_CALENDAR_IMPERSONATE` dari spatie/laravel-google-calendar.

Tanda tangan RS256 token service account dicek di test dengan public key, dan
sudah dibandingkan byte demi byte dengan tanda tangan OpenSSL untuk kunci dan
input yang sama.
