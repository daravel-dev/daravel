# Virtual classroom (example)

English · [Bahasa Indonesia](README.id.md)

A small Daravel application that schedules lessons and holds them in
LiveKit video rooms: the kind of feature a school platform adds once its
classes move online. It shows how the first-party packages fit together in
one application:

| Package | Used for |
| :-- | :-- |
| `daravel_livekit` | The room of each lesson, and a signed token per participant |
| `daravel_google` | The lesson in the school's Google Calendar, students as guests |
| `daravel_permission` | `teacher` and `student` roles, the `role:teacher` middleware |
| `daravel_teorion` | `?q=`, `?status=`, `?date=`, `?sort=` on the list of lessons |
| `daravel_activitylog` | Who changed which lesson, and when |

## The API

Every route needs a bearer token (`auth`).

| Route | Who | What it does |
| :-- | :-- | :-- |
| `GET /api/meetings` | Everyone | The lessons of the user's classrooms; students see the published ones |
| `POST /api/classrooms/{classroom}/meetings` | The classroom's teacher | Schedules a lesson; a published one is put in the calendar with the students as guests |
| `GET /api/meetings/{id}` | Teacher, students when published | One lesson |
| `PATCH /api/meetings/{id}` | The teacher | Reschedules, publishes or unpublishes; the calendar follows |
| `DELETE /api/meetings/{id}` | The teacher | Deletes it and its calendar event |
| `POST /api/meetings/{id}/join` | Teacher, students when published | `{url, room, token, expires_at, admin}` for a LiveKit client |

Joining opens 15 minutes before the start and closes at the end; the token
stays valid 15 minutes after the end. The teacher's token makes them the
room's admin (mute, remove participants); students join and publish.

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

## Run it

```bash
cp .env.example .env
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart migrate --seed     # a teacher, three students, a lesson in ten minutes
livekit-server --dev &                        # LIVEKIT_API_KEY=devkey, LIVEKIT_API_SECRET=secret
dart run bin/dartisan.dart serve
dart run bin/dartisan.dart queue:work         # calendar invitations
```

`dart test` runs the feature tests without LiveKit or Google: their HTTP
calls are faked and checked.

## Bringing it to an existing Laravel application

The tables are plain Laravel tables. An application that already has
lessons in Laravel can point this code at its own `meetings` table (rename
the columns in the model and the migration, or skip the migration), share
`personal_access_tokens` and the Spatie permission tables, and move the
lesson routes to Daravel one at a time behind a proxy, as
[Migrating from Laravel](../../docs/guide/migrating-from-laravel.md)
describes.
