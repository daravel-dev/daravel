# CAT Exam Demo

English · [Bahasa Indonesia](README.id.md)

A Computer Assisted Test (CAT) built with Daravel: candidates sign in on one
device, answer a timed exam whose answers are saved as they choose them,
and get their score and rank the moment they finish. The exam follows the
Indonesian civil service selection (CPNS) format, with three subtests: civic
knowledge (TWK), general intelligence (TIU) and personal characteristics
(TKP). The page, the API messages and the questions come in English and
Indonesian.

| Feature | Where it is | Daravel feature used |
| :-- | :-- | :-- |
| One device per candidate, with a proctor reset | `ExamEngineService.verifyCandidateAndLock` | Models, transactions |
| Questions and options shuffled per candidate, answer keys never sent | `getQuestionsForSession` | A seeded `Random`; an in-memory question bank |
| Answers saved on every click, retried safely | `POST /api/exam/answer`, `idempotency_key` | Unique constraints, `ExamAnswer` upserts |
| A timer the client cannot change | `expires_at` checked on the server | `Clock.now()`, so tests freeze time |
| Instant score and live ranking | `finishExam`, `GET /api/exam/leaderboard` | Query builder ordering |
| English and Indonesian | `lib/lang/`, `question_bank_en.dart` | `withTranslations`, `trans()`, `SetLocaleMiddleware` |

## Requirements

- The Dart SDK 3.13 or newer: `dart --version`. The repository pins the
  version in `.fvmrc`; with [fvm](https://fvm.app), put `fvm` before every
  `dart` command below.
- Git and a browser. SQLite needs no installation: the `sqlite3` package
  ships it.

## Set it up

```bash
git clone https://github.com/daravel-dev/daravel.git
cd daravel
dart pub get                              # once, at the root of the repository

cd apps/cat_exam_demo
cp .env.example .env                      # PowerShell: Copy-Item .env.example .env
dart run bin/dartisan.dart key:generate   # writes APP_KEY into .env
dart run bin/dartisan.dart migrate --seed # database/database.sqlite, 5 candidates, 15 questions
```

`dart pub get` runs at the root because every example is a member of the
repository's pub workspace: one resolution for all packages.

## Run it

```bash
dart run bin/dartisan.dart serve          # http://127.0.0.1:8000, Ctrl+C stops it
```

The exam lasts `EXAM_DURATION_MINUTES` (30) with a grace period of
`EXAM_GRACE_PERIOD_SECONDS` (15), both in `.env`.

## Try it

Open <http://127.0.0.1:8000> and pick a demo candidate:

| Candidate | NIK | Exam number | Try |
| :-- | :-- | :-- | :-- |
| Budi Santoso | `3201011203950001` | `TKA-2026-001` | The whole exam: answer, mark as doubtful, finish, see the score |
| Siti Rahmawati | `3201015508960002` | `TKA-2026-002` | A second candidate, to see the ranking |
| Ahmad Fauzi | `3201012211940003` | `TKA-2026-003` | The device lock: sign in here, then in another browser (or a private window) and get the conflict screen; **Reset the device lock** plays the proctor |

Refresh the page during the exam: the session resumes with the answers and
the time left. **EN | ID** in the header switches the language; the API
follows it through `Accept-Language`.

The same flow from a terminal:

```bash
curl -s -X POST http://127.0.0.1:8000/api/exam/verify \
  -H 'Content-Type: application/json' \
  -d '{"nik": "3201011203950001", "exam_number": "TKA-2026-001", "device_id": "pc-1"}'
# {"status": "created", "token": "cat_...", ...}

curl -s http://127.0.0.1:8000/api/exam/questions -H 'Authorization: Bearer cat_...'
curl -s http://127.0.0.1:8000/api/exam/questions -H 'Authorization: Bearer cat_...' -H 'Accept-Language: id'
```

## The API

| Route | What it does |
| :-- | :-- |
| `POST /api/exam/verify` | Signs a candidate in on a device: `created`, `resumed`, or `completed`; `409 DEVICE_LOCK_CONFLICT` on another device |
| `GET /api/exam/session` | The session and its time left |
| `GET /api/exam/questions` | The candidate's questions, shuffled, without answer keys |
| `POST /api/exam/answer` | Saves one answer; `410 EXAM_EXPIRED` after the time |
| `POST /api/exam/batch-answers` | Saves answers queued while offline |
| `POST /api/exam/finish` | Ends the exam and scores it |
| `GET /api/exam/result/{sessionId}` | The score sheet and rank |
| `GET /api/exam/leaderboard` | The ranking: total, then TKP, TIU, TWK, then the earlier submission |
| `POST /api/exam/proctor/reset-lock` | Releases a candidate's device lock |

## Test it

```bash
dart test                                 # in apps/cat_exam_demo
```

21 tests: the whole candidate journey, the device lock, the server-side
timer, 50 parallel answer saves, scoring and tie-breaking, edge cases, and
both languages.

## Build a native binary

```bash
dart build cli -t bin/server.dart -o build/cat_server
build/cat_server/bundle/bin/server        # .exe on Windows; needs .env beside it
```

## When something goes wrong

| Symptom | Cause and fix |
| :-- | :-- |
| `pub get` rejects the SDK constraint | The Dart SDK is older than 3.13: upgrade it, or use `fvm dart` |
| `Address already in use` | Another program has port 8000: set `APP_PORT` in `.env` |
| `APP_KEY is not set` | `.env` has no key: run `key:generate` |
| `no such table: candidates` | The database is not migrated: run `migrate --seed` |
| A candidate shows the result screen at once | They finished already: run `migrate:fresh --seed` (with `APP_ENV=local`) to start over |
| Windows: `Cannot delete file ... sqlite3.dll` when testing | A running server holds the SQLite library: stop it, then test |

## Use it outside this repository

Copy the folder, remove the line `resolution: workspace` from
`pubspec.yaml`, change each `any` constraint on a Daravel package to the
current release (for example `^1.24.0`), and run `dart pub get` in the
folder.

## How it holds up at the start of an exam

Every candidate of a session signs in within the same few minutes, then
saves an answer every few seconds. The numbers below are arithmetic on
that pattern, not measurements:

| | 20,000 candidates at once | 100,000 candidates at once |
| :-- | :-- | :-- |
| Sign-ins, spread over 3 minutes | about 110 per second | about 560 per second |
| Answer saves, one per candidate every 20 s | about 1,000 per second | about 5,000 per second |
| Upload, at about 280 bytes a save | about 2.2 Mbit/s | about 11 Mbit/s |

What the code does for that load:

- Questions are served from memory, so delivering them reads nothing from
  the database; only sign-in, saves and scoring write.
- An answer save is one upsert keyed by session and question, and the
  `idempotency_key` makes a retried request harmless.
- `dart run bin/dartisan.dart serve --isolates=N` runs N worker isolates
  on one port. With more than one process or machine, use PostgreSQL or
  MySQL instead of SQLite.

To measure a deployment, use the benchmark harness in
[`bench/`](../../bench).

## Where things are

| Path | Holds |
| :-- | :-- |
| `bootstrap/app.dart` | The application, its translations and middleware |
| `routes/api.dart`, `routes/web.dart` | The API and the page |
| `lib/app/services/exam_engine_service.dart` | Sign-in, device lock, saves, timer, scoring, ranking |
| `lib/app/services/question_bank.dart`, `question_bank_en.dart` | The questions in Indonesian and English |
| `lib/lang/` | The translated lines of the API and the page |
| `lib/resources/views/cat_exam_page.dart` | The page, HTML and plain JavaScript |
| `database/migrations/`, `database/seeders/` | The tables and the demo candidates |
| `test/` | The tests |
