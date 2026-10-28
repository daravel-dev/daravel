# dartisan

`dartisan` is Daravel's `artisan`. Install it once, then use it in any
project:

```bash
dart pub global activate dartisan_cli
dartisan new blog                       # or --template=minimal
cd blog && dartisan migrate --seed && dartisan serve --watch
```

Inside a project the global `dartisan` runs the project's own CLI,
`bin/dartisan.dart`, which knows your application and your own commands
(`bootstrap/commands.dart`). `dartisan <command> --help` lists a command's
options.

## Project

| Command | What it does |
| :-- | :-- |
| `about` | Versions, environment, drivers and paths |
| `doctor [--production]` | Checks configuration, database, storage and the port |
| `key:generate [--show] [--force]` | Writes a new `APP_KEY` |
| `env:encrypt`, `env:decrypt`, `env:obfuscate` | Encrypted `.env` files, see [Configuration](configuration.md) |
| `adopt <laravel-path> [--check]` | Shares the database and keys of a Laravel app, see [Migrating from Laravel](migrating-from-laravel.md) |
| `down [--secret] [--retry]`, `up` | Maintenance mode, see [Deployment](deployment.md#maintenance-mode) |
| `stub:publish` | Copies the generator templates into `stubs/` |
| `lint [--json]` | `daravel_lints` rules and registry checks |
| `security:audit [--target] [--format=terminal\|json\|sarif] [--output] [--severity] [--only] [--json-path]` | Black-box audit of a running server for deployment mistakes, see [Security](security.md#auditing-a-running-server) |
| `mcp:serve [--allow-write]`, `mcp:install` | Project context for AI coding agents over MCP, see [below](#ai-coding-agents-mcp) |
| `upgrade [--check] [--to] [--no-global] [--no-get]`, `self-update` | Move the project and the global CLI to a release, see [below](#upgrading) |
| `pub:list [--json]`, `pub:search <term> [--online]`, `pub:add <package...> [--yes] [--no-get]` | Find and install first-party packages, see [below](#packages) |
| `--version` (`-V`) | The version of the CLI or, in a project, of its framework |

### Packages

`dartisan pub:add` (alias `install`) installs a first-party package and
wires it up: the dependency in `pubspec.yaml`, its `.with*()` call in
`bootstrap/app.dart`, its migrations and commands in the registries, and
its settings in `.env.example` (never in `.env`). The database and Redis
packages run `db:install` and `redis:install`.

```bash
dartisan pub:list                  # the first-party packages and what is installed
dartisan pub:search permission     # by name, alias or description
dartisan pub:search excel --online # also pub.dev
dartisan pub:add rbac activitylog  # several at once; rbac is an alias of permission
```

A name must match a package or an alias exactly: a typo stops with
"Did you mean …?" instead of guessing. A package that is not part of
Daravel goes through `dart pub add` after you confirm it, or with `--yes`.
Without a terminal, `pub:add` never asks: an ambiguous name exits with
code 64. A project on a local checkout (`--path`) gets the package from the
same checkout.

### Upgrading

`dartisan upgrade` moves a project to the latest release on pub.dev: it
sets every Daravel package in `pubspec.yaml` (`daravel`, `dartisan_cli`,
`daravel_test`, `daravel_lints` and the driver packages) to `^<version>`,
runs `dart pub upgrade`, and activates the same version of the global
`dartisan`. Packages from git or a path, and `dependency_overrides`, are
left as they are.

```bash
dartisan upgrade --check        # installed and latest version, nothing changes
dartisan upgrade                # the latest release
dartisan upgrade --to=1.8.1     # a given version
dartisan self-update            # only the global dartisan
```

The global `dartisan` runs both itself, so they also work in a project
whose own CLI is older than the commands. Read the
[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md)
before moving to a new minor version.

## Serve, test and build

| Command | What it does |
| :-- | :-- |
| `serve [--watch] [--isolates=N] [--embed-queue] [--embed-scheduler]` | HTTP server; `--watch` hot-reloads |
| `test [--conformance] [--security] [--coverage]` | Runs the tests |
| `build [--with-cli] [--docker [--distroless]] [--no-sqlite]` | Native bundle in `build/server/bundle`, optional `Dockerfile` (`--distroless`: no shell, non-root, see [Deployment](deployment.md#docker)); `--no-sqlite` leaves the SQLite library out (PostgreSQL/MySQL apps) |
| `route:list` | The route table |
| `openapi:generate [--output]` | OpenAPI 3.1 from the routes and their declared metadata |
| `client:flutter [--output] [--package-name] [--prefix] [--state] [--watch]` | A typed Dart/Flutter client package from the routes, with the server's validation rules ([Flutter client](flutter-client.md)) |

## Database

| Command | What it does |
| :-- | :-- |
| `migrate [--seed [--force]]`, `migrate:status` | Migrations (seeding is refused in production without `--force`) |
| `migrate:rollback [--step] [--force]`, `migrate:reset [--force]` | Roll back the last batches, or everything (refused in production without `--force`) |
| `migrate:fresh [--seed] [--force]` | Drops every table and migrates again (refused in production without `--force`) |
| `db:seed [--class] [--force]` | Runs seeders (refused in production without `--force`) |
| `db:show`, `db:table <table> [--limit]` | Tables, columns and rows |
| `db:install <driver> [--no-get]` | Adds a driver package (`sqlite`, `pgsql`, `mysql`, `mariadb`) and registers it ([Database](database.md#drivers-and-connections)) |
| `redis:install [--docker] [--server=valkey\|redis] [--no-get]` | Adds daravel_redis, registers `.withRedis()` and its commands, documents its `.env` keys and, with `--docker`, a Valkey service ([Redis](redis.md)) |
| `db:transfer --from --to [--dry-run] [--truncate] [--tables] [--no-migrate]` | Copies the data to another database, migrating it first ([Database](database.md#copying-data-between-databases)) |
| `db:backup [--output] [--keep=N]` | Hot backup of the SQLite database into `storage/backups` (see [Deployment](deployment.md#backups)) |
| `tinker "<expression>"` | Evaluates a Dart expression in the booted application |
| `model:sync [Model]` | Regenerates a model's typed accessors from its table |
| `model:show <Model> [--json]` | A model's table, attributes (type, cast, fillable, hidden) and relations, from `bootstrap/models.dart` |
| `daragic:export [--out] [--only]` | The application model (DAM) for `daragic`: routes, models, migrations, schema, schedule, ... (see [Migrating from Laravel](migrating-from-laravel.md#the-application-model-daragic)) |

## Queues and scheduling

| Command | What it does |
| :-- | :-- |
| `queue:work [--queue] [--tries] [--max-time] [--stop-when-empty]` | Processes jobs; stops after the current job on `SIGTERM` |
| `queue:failed`, `queue:retry`, `queue:forget`, `queue:flush` | Failed jobs |
| `queue:clear`, `queue:pause`, `queue:continue`, `queue:restart` | Queue control |
| `schedule:work`, `schedule:run`, `schedule:list` | The scheduler |
| `cache:clear`, `storage:link`, `coordinator:stats [--url] [--token] [--json]` | Cache, public storage link, the running server's coordinator with advice ([Operations](operations.md#what-to-watch)) |

## Generators

`make:model [-m -f -s -c -p -r --api --all]`, `make:migration`,
`make:seeder`, `make:factory`, `make:controller [--api --resource --model]`,
`make:request`, `make:middleware`, `make:job`, `make:policy`, `make:event`,
`make:listener`, `make:resource`, `make:rule`, `make:mail`,
`make:notification`, `make:observer`, `make:query-filter` (daravel_teorion),
`make:provider`, `make:command` and `make:test`. Each one writes the file
from a template and adds it to the matching registry in `bootstrap/`.

## AI coding agents (MCP)

`dartisan mcp:serve` is a [Model Context Protocol](https://modelcontextprotocol.io)
server on stdio, Daravel's counterpart to Laravel Boost. It boots the project's
application, so agents see the application as it is, not a guess:

| Tool | Answers with |
| :-- | :-- |
| `about` | Daravel and Dart versions, environment, drivers |
| `routes` | Methods, URI, name, action, middleware, validation rules and their JSON Schema, documented response |
| `schema` | Tables with column and row counts, or one table's columns |
| `models` | The registered models and their relations, or one model's attributes, keys and relations |
| `db_query` | One `SELECT`/`WITH`/`EXPLAIN` statement, at most 100 rows by default; always rolled back, and read-only in the database on SQLite (`query_only`) and PostgreSQL (`READ ONLY`) |
| `read_logs`, `last_error` | The newest records of the daily log files (`LOG_STACK` with `daily`), or the newest error |
| `conventions` | Registries, generators, the model pattern, time, locked Laravel formats, lint rules |
| `docs_search` | The best sections of this guide, for the installed version |
| `run_command` | Runs a dartisan command (`--allow-write` only) |

It is read-only unless started with `--allow-write`. Even then,
`run_command` refuses long-running commands (`serve`, `queue:work`,
`schedule:work`, `tinker`) and, with `APP_ENV=production`, destructive ones
(`migrate:fresh`, `migrate:reset`, `migrate:rollback`, `db:seed`,
`queue:flush`, `queue:clear`, `key:generate`, `env:decrypt`, `env:encrypt`,
`down`). Protocol messages use stdout; logs go to stderr.

Packages add tools through the commands they register: a command that is an
`McpToolSource` brings its `McpTool`s. With `redisCommands` in
`bootstrap/commands.dart`, agents get `redis_inspect` (what a key holds, or
the keys of a pattern; values hidden in production). A tool that writes is
offered with `--allow-write` only.

`dartisan mcp:install` sets a project up for agents, like Laravel's
`boost:install`:

```bash
dart run bin/dartisan.dart mcp:install                          # .mcp.json + AGENTS.md
dart run bin/dartisan.dart mcp:install --guidelines=CLAUDE.md   # guidelines elsewhere
dartisan new blog --mcp                                         # the same, for a new project
```

It adds a `daravel` server to `.mcp.json` (other servers are kept; `--force`
replaces an existing `daravel` entry) and writes the Daravel conventions
between `<!-- daravel:guidelines -->` markers in `AGENTS.md`. Running it
again after an upgrade refreshes that section and leaves the rest of the
file alone. Claude Code reads `.mcp.json` from the project; to register the
server by hand instead:

```bash
claude mcp add daravel -- dart run bin/dartisan.dart mcp:serve
```

The `.mcp.json` entry, which other MCP clients read too:

```json
{
  "mcpServers": {
    "daravel": {
      "command": "dart",
      "args": ["run", "bin/dartisan.dart", "mcp:serve"]
    }
  }
}
```

### DDEV

In a [DDEV](https://ddev.com) project (one with `.ddev/config.yaml`), the
packages are resolved inside the web container, so a `dart` on the host
cannot run the project's CLI. `mcp:install` sees this and registers the
server in the container instead:

```json
{
  "mcpServers": {
    "daravel": {
      "command": "ddev",
      "args": ["dartisan", "mcp:serve"]
    }
  }
}
```

It also adds the custom command `.ddev/commands/web/dartisan` when it is
missing, so `ddev dartisan migrate` and the other commands run in the
container too. An entry still at the host default (`dart run ...`) is
replaced, because it cannot work there. An entry you changed is kept.
After adding DDEV to an existing project, run
`ddev dartisan mcp:install` again. `dartisan new --mcp` runs before DDEV
is configured, so it writes the host entry.

## Your own commands

```dart
final class SendReports extends DaravelCommand {
  SendReports(super.createApp);

  @override
  String get name => 'reports:send';

  @override
  String get description => 'Email the weekly reports.';

  @override
  Future<int> run() => withApp((app) async {
    // The application is booted; facades work here.
    return 0;
  });
}
```

`dartisan make:command SendReports` writes this and registers it in
`bootstrap/commands.dart`.
