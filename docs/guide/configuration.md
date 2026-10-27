# Configuration

## Environment files

Configuration comes from the environment, read in this order (later wins):

1. `.env` in the project root;
2. `.env.{APP_ENV}` (for example `.env.testing`), when `APP_ENV` is set;
3. the process environment;
4. overrides passed in code (`withEnv({...})`, used by tests).

The syntax is Laravel's (phpdotenv 5): comments, `export`, single and
double quotes, escapes in double quotes, values in double quotes that span
several lines, and `${NAME}` references. A bare `$NAME` stays as written, so
a password such as `p$ss` reads the same in Laravel and Daravel.

`dartisan key:generate` writes a fresh `APP_KEY`. Without a `.env`,
`APP_ENV` defaults to `production`.

## Encrypted environment files

`dartisan env:encrypt` writes `.env.encrypted` in the format of
`php artisan env:encrypt`; set `DARAVEL_ENV_ENCRYPTION_KEY` (or
`LARAVEL_ENV_ENCRYPTION_KEY`) and the application decrypts it in memory at
boot. See [Deployment](deployment.md#secrets-encrypted-environment-files).

## Typed configuration

Each module reads its variables into a typed section (`AppConfig`,
`DatabaseConfig`, `CacheConfig`, `QueueConfig`, ...), validated at boot:
debug mode in production, a malformed `APP_KEY` or an unknown
`DB_CONNECTION` stop the application with a clear message.

```dart
final app = Config.section<AppConfig>();      // typed
final name = Config.get<String>('app.name');  // dot notation, like config()
```

Your own settings get a section too:

```dart
final class BillingConfig implements ConfigSection {
  BillingConfig(this.currency, this.trialDays);

  factory BillingConfig.fromEnv(Env env) => BillingConfig(
    env.string('BILLING_CURRENCY', 'IDR'),
    env.integer('BILLING_TRIAL_DAYS', 14),
  );

  final String currency;
  final int trialDays;

  @override
  String get key => 'billing';

  @override
  Map<String, Object?> toMap() => {'currency': currency, 'trial_days': trialDays};
}

// bootstrap/app.dart
Application.configure(basePath: '.').withConfig(BillingConfig.fromEnv);
```

`Env` has typed readers: `string`, `integer`, `boolean`, `duration`
(`30s`, `5m`, `500ms`), `list`, `url` and `enumValue`. Configuration is
frozen after boot.

## Common variables

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `APP_ENV`, `APP_DEBUG` | `production`, `false` | Environment and debug output |
| `APP_KEY`, `APP_PREVIOUS_KEYS` | none | Encryption, signed URLs, tokens; key rotation |
| `APP_CIPHER` | `AES-256-CBC` | `Crypt` cipher (as Laravel) |
| `APP_HOST`, `APP_PORT`, `PORT` | `127.0.0.1`, `8000` | Server address; `PORT` for container platforms |
| `APP_ISOLATES` | `1` | HTTP worker isolates |
| `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` | `sqlite` | `sqlite`, `pgsql`, `mysql` or `mariadb` (a path in `DB_HOST` is a PostgreSQL Unix socket) |
| `DB_URL` | | One URL instead of the keys above, as in Laravel 12: `postgres://user:pass@host:5432/app?sslmode=require`. Its parts replace the matching `DB_*` values; those it leaves out stay ([Database](database.md#database-urls)) |
| `MAIL_MAILER` | `log` (`array` in tests) | `smtp`, `log`, `array` or a registered transport ([Mail](mail.md)) |
| `MAIL_SCHEME`, `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD` | `smtp`, `127.0.0.1`, `2525` | SMTP server; `smtps` (or port 465) for TLS from the start |
| `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME` | `hello@example.com`, `APP_NAME` | The default sender |
| `BROADCAST_CONNECTION` | `daravel` | Where broadcast events go: `daravel` (this server), `reverb`, `pusher`, `log`, `null` ([Broadcasting](broadcasting.md)) |
| `REVERB_APP_ID`, `REVERB_APP_KEY`, `REVERB_APP_SECRET` | none | The Pusher app this server serves Echo with (or the Reverb it sends to) |
| `REVERB_HOST`, `REVERB_PORT`, `REVERB_SCHEME` | none, 443, `https` | The Reverb `BROADCAST_CONNECTION=reverb` sends to |
| `REVERB_SCALING_ENABLED`, `REVERB_SCALING_CONNECTION` | `false`, default connection | Several servers share broadcasting through the database ([Broadcasting](broadcasting.md#several-servers)) |
| `REVERB_SCALING_DRIVER` | `database` | What the servers share through: `database`, or `redis` with [daravel_redis](redis.md) |
| `REVERB_SCALING_POLL`, `REVERB_SERVER_ID` | `100ms`, host and process id | How often servers read each other's events without `NOTIFY` (PostgreSQL has it), and this server's name |
| `REVERB_ENCRYPTION_MASTER_KEY_BASE64` | none | 32 bytes in base64 that `private-encrypted-` channels are encrypted with (`PUSHER_ENCRYPTION_MASTER_KEY_BASE64` with `pusher`) |
| `DB_CHARSET`, `DB_COLLATION`, `DB_TIMEZONE` | `utf8mb4`, `utf8mb4_unicode_ci`, server | MySQL and MariaDB, as Laravel reads them |
| `DB_POOL_SIZE`, `DB_SSLMODE` | `10`, `disable` | Connection pool per isolate, TLS (`require`, `verify-full`) |
| `CACHE_STORE`, `CACHE_PREFIX` | `memory` | Cache store and key prefix |
| `CACHE_PROCESS_L1_TTL` | `0` (off) | With the `process` store, how long each worker isolate reuses a value it read (`250ms`) before asking the coordinator again |
| `CACHE_LIMITER` | coordinator | Cache store for rate limits (Laravel's `cache.limiter`); `database` shares them between machines, with one statement per attempt |
| `QUEUE_CONNECTION` | `sync` | `sync`, `memory`, `database` or `redis` ([Redis](redis.md)) |
| `QUEUE_UNIQUE_LOCK_STORE` | `database` or `redis` with that queue, else `process` | Cache store of unique-job locks; `queue:work` processes must reach it |
| `QUEUE_SIGNAL_STORE` | `file` with the database queue, else the lock store | Cache store of `queue:restart` and `queue:pause` signals; `database` reaches workers on every machine |
| `HASH_DRIVER`, `BCRYPT_ROUNDS` | `bcrypt`, `12` | Password hashing (as Laravel) |
| `LOG_LEVEL`, `LOG_STACK` | `debug` | Logging level and channels (`json` for production) |
| `SHUTDOWN_TIMEOUT`, `HTTP_REQUEST_TIMEOUT` | `30s`, `30s` | Graceful shutdown and handler timeouts |
| `HTTP_MAX_QUEUE_DELAY`, `HTTP_MAX_IN_FLIGHT` | off (`200ms` in new projects), off | [Load shedding](deployment.md#load-shedding): `503` while a worker's event loop is this late, or above this many requests at once |
| `SERVER_EMBED_QUEUE`, `SERVER_EMBED_SCHEDULER` | `false` | Queue worker and scheduler in the server process |

`dartisan doctor` checks the configuration and the database connection;
`doctor --production` treats warnings as failures. Tuning advice (one
isolate on a machine with more cores, `LOG_LEVEL` below `warning`, a SQLite
file shared by several isolates, the PostgreSQL pool against
`max_connections`) is printed as `[note]` and never fails.
