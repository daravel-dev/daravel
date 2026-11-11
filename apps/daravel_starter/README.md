# Daravel starter

English · [Bahasa Indonesia](README.id.md)

The reference application of Daravel, and what `dartisan new` generates: a
welcome page, token authentication (register, login, logout, me), a users
API with validation, policies and resources, migrations, seeders,
factories, and tests. Its tests are the end-to-end specification of the
framework, so everything shown here is checked on every commit.

| Route | What it does |
| :-- | :-- |
| `GET /` | The welcome page |
| `GET /api/ping` | A health answer for monitors |
| `POST /api/auth/register` | Creates a user and returns a bearer token |
| `POST /api/auth/login` | Returns a bearer token for an email and password (5 tries a minute) |
| `GET /api/auth/me`, `POST /api/auth/logout` | The current user; revokes the token |
| `GET /api/users`, `GET /api/users/{id}`, `POST /api/users`, `PATCH /api/users/{id}` | The users API, paginated like Laravel |
| `GET /docs/api` | The live API reference, on while `APP_ENV=local` |
| `GET /up` | The health route |

## Requirements

- The Dart SDK 3.13 or newer: `dart --version`. The repository pins the
  version in `.fvmrc`; with [fvm](https://fvm.app), put `fvm` before every
  `dart` command below.
- Git. SQLite needs no installation: the `sqlite3` package ships it.

## Set it up

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # once, at the root of the repository

cd apps/daravel_starter
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # writes APP_KEY into .env
dart run bin/dartisan.dart migrate --seed # database/database.sqlite and 11 users
```

`dart pub get` runs at the root because every example is a member of the
repository's pub workspace: one resolution for all packages.

## Run it

```bash
dart run bin/dartisan.dart serve          # http://127.0.0.1:8000, Ctrl+C stops it
dart run bin/dartisan.dart serve --watch  # restarts when a file changes
```

## Try it

Open <http://127.0.0.1:8000> for the welcome page and
<http://127.0.0.1:8000/docs/api> for the API reference. The seeded user
`test@example.com` logs in with `password`:

```bash
curl -s -X POST http://127.0.0.1:8000/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email": "test@example.com", "password": "password"}'
# {"user": {...}, "token": "1|...", "token_type": "Bearer"}

curl -s http://127.0.0.1:8000/api/users -H 'Authorization: Bearer 1|...'
```

## Test it

```bash
dart test                                 # in apps/daravel_starter
```

## Build a native binary

```bash
dart build cli -t bin/server.dart -o build/server
build/server/bundle/bin/server            # .exe on Windows; needs .env beside it
```

## When something goes wrong

| Symptom | Cause and fix |
| :-- | :-- |
| `pub get` rejects the SDK constraint | The Dart SDK is older than 3.13: upgrade it, or use `fvm dart` |
| `Address already in use` | Another program has port 8000: set `APP_PORT` in `.env` |
| `APP_KEY is not set` | `.env` has no key: run `key:generate` |
| Windows: `Cannot delete file ... sqlite3.dll` when testing | A running server holds the SQLite library: stop it, then test |
| You want a clean database | Delete `database/database.sqlite` and run `migrate --seed` again |

## Use it outside this repository

To start a project of your own, `dartisan new` is the shorter way:

```bash
dart pub global activate dartisan_cli
dartisan new my_app
```

To copy this folder instead: remove the line `resolution: workspace` from
`pubspec.yaml`, change each `any` constraint on a Daravel package to the
current release (for example `^1.24.0`), and run `dart pub get` in the
folder.

Daravel is kept going by its sponsors: [github.com/sponsors/daravel-dev](https://github.com/sponsors/daravel-dev) (`dartisan sponsor`).
