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
dart pub global activate --source path packages/dartisan_cli   # from a Daravel checkout
dartisan new blog                  # api template: auth, users, tokens, tests
dartisan new tiny --template=minimal
cd blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch   # hot reload
```

Every project has a project-bound CLI, `bin/dartisan.dart`, that knows your
application (`createApp()` in `bootstrap/app.dart`). `dart run
bin/dartisan.dart help` lists every command.

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
dart run bin/dartisan.dart make:model Post --migration --factory
dart run bin/dartisan.dart make:controller PostController --api --model=Post
dart run bin/dartisan.dart make:request StorePostRequest
dart run bin/dartisan.dart make:job PublishPost
```

Templates live in `dartisan_cli`; `stub:publish` copies them into `stubs/`
so you can change them.

## Build and run

```bash
dart run bin/dartisan.dart build           # dart build cli → build/server/bundle
APP_ISOLATES=4 ./build/server/bundle/bin/server
dart run bin/dartisan.dart build --docker  # multi-stage Dockerfile
```

The bundle is a directory: `bin/server` plus `lib/` with the bundled SQLite.
Deploy the whole directory. See [Deployment](deployment.md).
