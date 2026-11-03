# Virtual classroom (example)

English · [Bahasa Indonesia](README.id.md)

A small Daravel application that schedules lessons and holds them in
LiveKit video rooms: the kind of feature a school platform adds once its
classes move online. It shows how the first-party packages fit together in
one application, with a browser page to try it:

| Package | Used for |
| :-- | :-- |
| `daravel_livekit` | The room of each lesson, and a signed token per participant |
| `daravel_google` | The lesson in the school's Google Calendar, students as guests |
| `daravel_permission` | `teacher` and `student` roles, the `role:teacher` middleware |
| `daravel_teorion` | `?q=`, `?status=`, `?date=`, `?sort=` on the list of lessons |
| `daravel_activitylog` | Who changed which lesson, and when |

The page and the API messages come in English and Indonesian: **EN | ID** in
the header, or `Accept-Language`.

## Requirements

- The Dart SDK 3.13 or newer: `dart --version`. The repository pins the
  version in `.fvmrc`; with [fvm](https://fvm.app), put `fvm` before every
  `dart` command below.
- Git, and a browser with a camera and microphone for the video.
- For the video rooms: a **LiveKit server**. It is an external service and
  is not part of this repository; see [LiveKit](#livekit). Without one,
  everything but the video works.
- For calendar invitations: a **Google service account**, optional; see
  [Google Calendar](#google-calendar).

## Set it up

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # once, at the root of the repository

cd apps/virtual_classroom
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # writes APP_KEY into .env
dart run bin/dartisan.dart migrate --seed # a teacher, three students, a lesson in ten minutes
```

Every seeded user logs in with `password`: `teacher@example.com`, and
`student1@example.com` to `student3@example.com`.

## LiveKit

LiveKit is the video server the browser connects to. Install and run it
apart from this repository, in any of these ways, and never copy its binary
or configuration into the app folder (`.gitignore` refuses them):

| Where | How |
| :-- | :-- |
| Docker | `docker run --rm -p 7880:7880 -p 7881:7881 -p 7882:7882/udp livekit/livekit-server --dev --bind 0.0.0.0` |
| macOS | `brew install livekit`, then `livekit-server --dev` |
| Linux | `curl -sSL https://get.livekit.io \| bash`, then `livekit-server --dev` |
| Windows | A release from [github.com/livekit/livekit/releases](https://github.com/livekit/livekit/releases), then `livekit-server.exe --dev` |
| LiveKit Cloud | Create a project and copy its URL, key and secret into `.env` |

`--dev` starts a local server with the key `devkey` and the secret `secret`,
which `.env.example` already holds, with `LIVEKIT_URL=ws://127.0.0.1:7880`.
With LiveKit Cloud or your own deployment, set `LIVEKIT_URL` (`wss://...`),
`LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` instead.

When the server runs in Docker inside WSL and the browser on Windows, add
`--node-ip 127.0.0.1`, so that the browser reaches the media ports through
WSL's port forwarding.

## Google Calendar

Optional. Leave `GOOGLE_APPLICATION_CREDENTIALS` empty and lessons are
scheduled without invitations; the page's calendar view then shows what
would be sent.

To send invitations, create a service account in Google Cloud, share the
school's calendar with it, download its JSON key **outside the repository**,
and point `.env` at it:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/path/outside/the/repo/service-account.json
GOOGLE_CALENDAR_ID=school@example.org
```

## Run it

```bash
dart run bin/dartisan.dart serve          # http://127.0.0.1:8000, Ctrl+C stops it
dart run bin/dartisan.dart queue:work     # in another terminal: calendar invitations
```

## Try it

1. Open <http://127.0.0.1:8000>. The page signs you in as the teacher.
2. **Join the LiveKit room** of the seeded lesson. The browser asks for the
   camera and microphone, then shows you in the room.
3. Open a second tab, click **Student 1**, and join the same lesson: each
   tab sees the other.
4. As the student, **Raise hand**: the teacher sees ✋. As the teacher,
   **Mute everyone**: the student's microphone turns off.
5. Click **Outsider** and try to join: the API answers 403.
6. **Schedule a new lesson** as the teacher, publish or unpublish it, and
   look at **Google Calendar** and **Activity Log**.

The room opens 15 minutes before a lesson starts and closes when it ends
(409 outside that window). Without a LiveKit server the room shows a notice
and the signed token, which you can still inspect.

## The API

| Route | Who | What it does |
| :-- | :-- | :-- |
| `POST /api/auth/login` | Everyone | A bearer token for an email and password (5 tries a minute) |
| `GET /api/auth/me` | Signed in | The current user and role |
| `GET /api/meetings` | Signed in | The lessons of the user's classrooms; students see the published ones |
| `POST /api/classrooms/{classroom}/meetings` | The classroom's teacher | Schedules a lesson; a published one is put in the calendar with the students as guests |
| `GET /api/meetings/{id}` | Teacher, students when published | One lesson |
| `PATCH /api/meetings/{id}` | The teacher | Reschedules, publishes or unpublishes; the calendar follows |
| `DELETE /api/meetings/{id}` | The teacher | Deletes it and its calendar event |
| `POST /api/meetings/{id}/join` | Teacher, students when published | `{url, room, token, expires_at, admin}` for a LiveKit client |
| `POST /api/auth/demo-switch`, `GET /api/demo/state`, `GET /api/activity-logs` | Demo only | The page's account switcher and side panels |

The demo routes give out tokens without a password and list every user, so
they answer only while `APP_ENV` is `local` or `testing`, and 404 anywhere
else. Keep `APP_ENV=production` on a server.

Joining opens 15 minutes before the start and closes at the end; the token
stays valid 15 minutes after the end. The teacher's token makes them the
room's admin; students join and publish. Raising a hand and muting everyone
travel as LiveKit data messages, and a client obeys a mute only from a
participant whose signed token says `teacher`.

## Built for the first minute of class

Every student of a school joins in the same minute. The join endpoint is
written for that:

- `CreateRoom` returns the room when it exists, so the first of many
  students does not have to win a race to create it, and no `ListRooms`
  call is spent on every join.
- A token is signed in the request (HMAC, microseconds); nothing waits on
  the calendar or any other slow service.
- `throttle:join` allows ten tries a minute per user and lesson, so a
  client retrying in a loop cannot take the room service's capacity.
- Calendar invitations go through the queue after the transaction commits;
  a slow or failing Google API never delays or fails a request.

## Test it

```bash
dart test                                 # in apps/virtual_classroom
```

The tests need neither LiveKit nor Google: their HTTP calls are faked and
checked.

## When something goes wrong

| Symptom | Cause and fix |
| :-- | :-- |
| The room says LiveKit is not reachable | No LiveKit server at `LIVEKIT_URL`: start one (see [LiveKit](#livekit)) |
| Connected, but no video between Windows and WSL | Start the WSL server with `--node-ip 127.0.0.1` |
| `409` when joining | The lesson is outside its room window: schedule one with **Room open now** |
| `403` when joining | The user is neither the classroom's teacher nor one of its students |
| No calendar invitations | `GOOGLE_APPLICATION_CREDENTIALS` is empty, or `queue:work` is not running |
| `APP_KEY is not set` | `.env` has no key: run `key:generate` |
| You want a clean database | Delete `database/database.sqlite` and run `migrate --seed` again |

## Use it outside this repository

Copy the folder, remove the line `resolution: workspace` from
`pubspec.yaml`, change each `any` constraint on a Daravel package to the
current release (for example `^1.24.0`), and run `dart pub get` in the
folder.

## Bringing it to an existing Laravel application

The tables are plain Laravel tables. An application that already has
lessons in Laravel can point this code at its own `meetings` table (rename
the columns in the model and the migration, or skip the migration), share
`personal_access_tokens` and the Spatie permission tables, and move the
lesson routes to Daravel one at a time behind a proxy, as
[Migrating from Laravel](../../docs/guide/migrating-from-laravel.md)
describes.
