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
| `mcp:serve [--allow-write]`, `mcp:install` | Project context for AI coding agents over MCP, see [below](#ai-coding-agents-mcp) |

## Serve, test and build

| Command | What it does |
| :-- | :-- |
| `serve [--watch] [--isolates=N] [--embed-queue] [--embed-scheduler]` | HTTP server; `--watch` hot-reloads |
| `test [--conformance] [--security] [--coverage]` | Runs the tests |
| `build [--with-cli] [--docker] [--no-sqlite]` | Native bundle in `build/server/bundle`, optional `Dockerfile`; `--no-sqlite` leaves the SQLite library out (PostgreSQL/MySQL apps) |
| `route:list` | The route table |
| `openapi:generate [--output]` | OpenAPI 3.1 from the routes and their declared metadata |

## Database

| Command | What it does |
| :-- | :-- |
| `migrate [--seed]`, `migrate:status`, `migrate:rollback`, `migrate:reset` | Migrations |
| `migrate:fresh [--seed] [--force]` | Drops every table and migrates again (refused in production without `--force`) |
| `db:seed [--class]` | Runs seeders |
| `db:show`, `db:table <table> [--limit]` | Tables, columns and rows |
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
| `cache:clear`, `storage:link`, `coordinator:stats` | Cache, public storage link, coordinator state |

## Generators

`make:model [-m -f -s -c -p -r --api --all]`, `make:migration`,
`make:seeder`, `make:factory`, `make:controller [--api --resource --model]`,
`make:request`, `make:middleware`, `make:job`, `make:policy`, `make:event`,
`make:listener`, `make:resource`, `make:rule`, `make:observer`,
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
`queue:flush`, `queue:clear`, `key:generate`, `env:decrypt`). Protocol messages
use stdout; logs go to stderr.

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
