# Log viewer

`daravel_log_viewer` serves a page, from your application, that reads its
log files: the newest entries first, filtered by level or text, a stack
trace a click away, and new entries as they are written. It reads a file
from its end, so the last entries of a 500 MB file come back in under a
millisecond, in the same memory as those of a small one.

```bash
dart pub add daravel_log_viewer
```

```dart
// bootstrap/app.dart
import 'package:daravel_log_viewer/daravel_log_viewer.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withLogViewer(middleware: ['auth', 'can:view-logs'])
    // ...
    .create();
```

The page is at `/log-viewer` (`LOG_VIEWER_PATH`, or `withLogViewer(path:
'/admin/logs')`). It reads the folder the daily log channel writes to
(`LOG_PATH`, `storage/logs`), so log to a file:

```dotenv
LOG_STACK=console,daily
```

## Who can see it

Logs say a lot about an application. Outside `APP_ENV=local` and `testing`
the viewer answers 403 until `withLogViewer` is given middleware, such as
`auth` and a gate:

```dart
// bootstrap/policies.dart
gate.define('view-logs', (user, args) => user is User && user.isAdmin);
```

`LOG_VIEWER_ENABLED=false` turns it off (404) everywhere.

## What it shows

- **Files.** Every `.log` file of the folder, newest first, with its size;
  `daravel-YYYY-MM-DD.log` files from Daravel and `laravel.log` from a
  Laravel application sharing the server alike.
- **Entries.** Time, level, message; a click shows the context (as JSON),
  the error and the stack trace, where the application's frames stand out
  from the framework's and the SDK's.
- **Levels and search.** Level chips (`emergency` to `debug`) and a search
  over the whole entry: a request id, a user id, an exception's class.
- **Live.** New entries appear as they are written, over server-sent
  events, filtered the same way.
- **Older entries.** Pages go back through the file without reading it
  from the start.

Daravel writes one JSON object per line (`time`, `level`, `channel`,
`message`, `context`, `error`, `trace`); Laravel writes Monolog lines
(`[2026-10-28 08:00:00] production.ERROR: ...`) followed by the stack
trace. Both are read. A line in neither format is shown as it is.

## Secrets

The logger already replaces the values of `LOG_REDACT` keys when it writes
an entry. The viewer also hides, before an entry leaves the server, the
values of `LOG_VIEWER_MASK_KEYS` keys (`password`, `secret`, `token`,
`authorization`, `cookie`, `api_key`, `app_key`, `credit_card` by default,
matched as parts of a key, ignoring case): in the context at any depth, and
in text such as `password=...`, `"token": "..."` or `Authorization: ...`.

The page loads nothing from other hosts: its script and styles are inline,
allowed by a fresh nonce in a `Content-Security-Policy` that permits
nothing else, and log text is only ever inserted as text, never as HTML.
A file name must be a `.log` file directly in the folder: paths, `..`,
hidden files and links out of the folder answer 404.

## Settings

| Variable | Default | |
| :-- | :-- | :-- |
| `LOG_VIEWER_ENABLED` | `true` | `false` answers 404 |
| `LOG_VIEWER_PATH` | `/log-viewer` | the page's URL |
| `LOG_VIEWER_DIRECTORY` | `LOG_PATH` | the folder of the log files |
| `LOG_VIEWER_PER_PAGE` | `50` | entries per page, at most 500 |
| `LOG_VIEWER_ALLOW_DOWNLOAD` | `true` | the Download button |
| `LOG_VIEWER_ALLOW_DELETE` | `false` | the Delete button (`DELETE` request) |
| `LOG_VIEWER_MASK_KEYS` | see above | keys whose values are hidden |
| `LOG_VIEWER_MAX_SCAN_MB` | `64` | how much of a file one filtered page reads before it offers to read on |

## The API

The page uses JSON endpoints under its path, which tools can use too
(behind the same middleware):

| | |
| :-- | :-- |
| `GET /log-viewer/api/files` | the files, newest first |
| `GET /log-viewer/api/entries?file=&levels=error,warning&search=&before=` | a page of entries, newest first, and `next`, the `before` of the older page |
| `GET /log-viewer/api/tail?file=&levels=&search=` | server-sent `entry` events |
| `GET /log-viewer/api/download?file=` | the file |
| `DELETE /log-viewer/api/files?file=` | deletes the file (when allowed) |

## Large files

`bench/bin/log_viewer_bench.dart` (an AOT build, Windows 11, Dart 3.13.4):

| File | Newest 50 entries | A search that matches nothing (64 MB read) | Peak memory |
| --: | --: | --: | --: |
| 100 MB | 0.8 ms | 1.2 s | 17 MB |
| 500 MB | 0.6 ms | 0.9 s | 17 MB |

The memory is the process's whole peak, the runtime included. Reading a
page or following a file holds a 64 KB block and one entry at a time.
