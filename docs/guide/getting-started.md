# Getting started

## Requirements

- Dart SDK `^3.13` (Flutter 3.47 or later ships it).
- Nothing else for SQLite: `package:sqlite3` downloads a hash-verified
  SQLite build at build time and ships it with your app. To use the
  operating system's library instead, add to `pubspec.yaml`:

  ```yaml
  hooks:
    user_defines:
      sqlite3:
        source: system
  ```

## Create a project

```bash
dart pub global activate dartisan_cli     # from pub.dev
dartisan new blog                  # api template: auth, users, tokens, tests
dartisan new tiny --template=minimal
cd blog
dartisan migrate --seed
dartisan serve --watch   # hot reload
```

Every project has a project-bound CLI, `bin/dartisan.dart`, that knows your
application (`createApp()` in `bootstrap/app.dart`). Inside a project the
global `dartisan` runs it, so `dartisan` alone lists every command, including
your own, and `dartisan migrate --help` shows a command's options.
`dart run bin/dartisan.dart <command>` is the same without the global tool.

## Project structure

The layout mirrors Laravel 12:

| Path | Purpose |
| :-- | :-- |
| `bootstrap/app.dart` | `createApp()`: routing, middleware, auth, rate limits, exceptions |
| `bootstrap/*.dart` | explicit registries: migrations, seeders, jobs, policies, listeners, commands |
| `routes/api.dart`, `routes/web.dart`, `routes/console.dart` | routes and the schedule |
| `lib/app/http/controllers`, `requests`, `resources` | HTTP layer |
| `lib/app/models`, `jobs`, `events`, `listeners`, `policies` | domain |
| `database/migrations`, `seeders`, `factories` | schema and data |
| `test/feature`, `test/unit`, `test/conformance` | tests |

Daravel uses no reflection and no code generation at build time. What
Laravel discovers automatically is listed explicitly in `bootstrap/`;
`dartisan make:*` generators add the entries for you, and
`dartisan lint` reports files missing from a registry.

## Generators

```bash
dartisan make:model Post --migration --factory
dartisan make:controller PostController --api --model=Post
dartisan make:request StorePostRequest
dartisan make:job PublishPost
```

Templates live in `dartisan_cli`; `stub:publish` copies them into `stubs/`
so you can change them.

## Inspecting the application

```bash
dartisan db:show                      # tables with column and row counts
dartisan db:table users --limit=5     # columns, then the first rows
dartisan tinker "await User.query().where('active', true).count()"
```

`tinker` evaluates one Dart expression inside the booted application (models
are imported for you) and prints the result, models and collections as JSON.
Dart has no `eval`, so each call compiles a small program and boots the
application again; it is one-shot, not a REPL.

## Build and run

```bash
dartisan build           # dart build cli → build/server/bundle
APP_ISOLATES=4 ./build/server/bundle/bin/server
dartisan build --docker  # multi-stage Dockerfile
```

The bundle is a directory: `bin/server` plus `lib/` with the bundled SQLite.
Deploy the whole directory. See [Deployment](deployment.md).
