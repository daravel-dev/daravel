# Database

`DB_CONNECTION` selects SQLite (`sqlite`, the default), PostgreSQL (`pgsql`),
MySQL (`mysql`) or MariaDB (`mariadb`). MySQL and MariaDB come from
`package:daravel_mysql`, which new projects register in `bootstrap/app.dart`:

```dart
Application.configure(basePath: '.')
    .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
    .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
```

SQLite and PostgreSQL are built in through Daravel 1.x. See [Drivers and
connections](#drivers-and-connections) for the driver packages and for
using several databases at once.

On MySQL, results read as in Laravel (`TINYINT(1)` as `0`/`1`, `DECIMAL` and
`JSON` as strings, dates as `Y-m-d H:i:s`), and the session time zone is the
server's unless `DB_TIMEZONE` is set, so `TIMESTAMP` columns read the same
from both frameworks. MySQL 8.4 and MariaDB 11 run in CI on every commit.
Every query is built by a grammar with bound values; identifiers are quoted.

Laravel sets `sql_mode` on each MySQL connection from the connection's
`'strict'` key (`true` in its default `config/database.php`). Daravel
leaves the server's mode unless told otherwise: `DB_STRICT=true` sets the
strict modes Laravel sets, `DB_STRICT=false` sets `NO_ENGINE_SUBSTITUTION`
as Laravel does with `'strict' => false` (an `INSERT` without a value for
a `NOT NULL` column then stores `''` or `0` instead of failing), and
`DB_SQL_MODES` sets an explicit list. Match the Laravel application that
shares the database. `DB_ISOLATION_LEVEL` sets the transaction isolation
level, and `MySqlDriver(initCommands: [...], onConnectionOpen: ...)` runs
anything else on each new connection.

## Drivers and connections

Each database client is a package. MySQL and MariaDB already work this way.
For SQLite (`daravel_sqlite`) and PostgreSQL (`daravel_postgres`), the
packages re-export the drivers that are still built into 1.x, so adding one
changes nothing today. In 2.0, `package:daravel` stops depending on any
database client, and the drivers live only in these packages. A project
that already depends on its driver package then upgrades without changes,
and no longer builds or ships the clients it does not use.

`dartisan db:install` adds a driver package, registers it and documents its
settings:

```bash
dart run bin/dartisan.dart db:install pgsql     # or sqlite, mysql, mariadb
```

| It changes | With |
| :-- | :-- |
| `pubspec.yaml` | `daravel_postgres: ^<version>` (then `dart pub get`; `--no-get` skips it) |
| `bootstrap/app.dart` | the import and `.withPostgres()` (`.withSqlite()`, or the MySQL `withDatabaseDriver` lines) after `Application.configure(...)` |
| `.env.example` | a commented block with the driver's `DB_*` keys; for PostgreSQL also `DB_POOL_SIZE=10` and `HTTP_MAX_IN_FLIGHT=40` ([load shedding](deployment.md#load-shedding) sized to the pool) |

Running it again changes nothing.

### SQLite or PostgreSQL

SQLite is for development, tests and deployments with one isolate.
PostgreSQL (or MySQL and MariaDB) is for production with `APP_ISOLATES`
greater than 1.

SQLite works with several isolates: every isolate opens the same file in
WAL mode and waits up to 5 seconds (`busy_timeout`) for another isolate's
write lock. But SQLite calls are synchronous, so while a worker waits for
that lock its whole event loop waits too, and so does every request on
that worker. Writes are serialized across the server. `serve` logs a
warning when it starts several isolates on a SQLite file, and
`dartisan doctor` notes it; see [Operations](operations.md) for sizing
PostgreSQL connections.

### Switching the default database

The models, queries and migrations do not depend on the driver. To move an
application from SQLite to PostgreSQL:

1. `dartisan db:install pgsql`.
2. In `.env`: `DB_CONNECTION=pgsql` and `DB_HOST`, `DB_PORT`, `DB_DATABASE`,
   `DB_USERNAME`, `DB_PASSWORD`.
3. `dartisan migrate`, or copy the existing data across with `db:transfer`
   (below), which migrates the new database first.

### Database URLs

`DB_URL` sets a database with one value, as in Laravel 12, so a `.env` that
uses it works for both frameworks:

```dotenv
DB_CONNECTION=pgsql
DB_URL=postgres://app:secret@db.internal:5432/shop?sslmode=require
```

It is merged the way Laravel's `ConfigurationUrlParser` merges it, and
Daravel's tests compare the result with Laravel's own:

- The scheme sets the driver: `postgres` and `postgresql` mean `pgsql`,
  `mysql2` means `mysql`, and `sqlite3` means `sqlite`.
- The host, port, user, password and database the URL contains replace the
  `DB_*` values. Parts it leaves out keep them (`DB_PORT`, `DB_DATABASE`,
  ...). User and password are URL-decoded, so write `@` as `%40`.
- The query string adds options (`sslmode`, `charset`, `timezone`, ...);
  `true`, `false`, `null` and numbers are read as such.

As in Laravel, `DB_URL` applies to every built-in connection, and
`DB_CONNECTION` picks which one is used.

### Several databases at once

The `DB_*` keys configure one database. Add others with their own settings
in `bootstrap/app.dart`, for example from a URL in Laravel's `DB_URL`
form:

```dart
Application.configure(basePath: basePath ?? Directory.current.path)
    .withDatabaseConnection(
      'legacy',
      (env) => ConnectionConfig.fromUrl(env.string('LEGACY_DB_URL')),
    )
```

```dotenv
LEGACY_DB_URL=mysql://shop:secret@10.0.0.5:3306/shop
```

`ConnectionConfig.fromUrl` reads `pgsql://`, `mysql://`, `mariadb://` and
`sqlite:` URLs, and the query string sets `sslmode`, `pool`, `charset` and
`timezone`. A connection whose driver is MySQL or MariaDB still needs that
driver registered (`db:install mysql`).

Queries and models pick a connection by name:

```dart
final orders = await DB.table('orders', connection: 'legacy').get();

final class LegacyOrder extends Model {
  static final ModelDefinition<LegacyOrder> definition =
      ModelDefinition<LegacyOrder>(
        table: 'orders',
        connection: 'legacy',
        factory: LegacyOrder.new,
      );
  @override
  ModelDefinition<LegacyOrder> get modelDefinition => LegacyOrder.definition;
}
```

Transactions are per connection, as in Laravel. Queries on another
connection inside `DB.transaction(...)` do not join it, so they commit even
when it rolls back. `DB.transaction(..., connection: 'legacy')` starts a
transaction of its own on that connection.

### Copying data between databases

`dartisan db:transfer` copies an application's data to another database,
for example from the SQLite file used in development to PostgreSQL:

```bash
dart run bin/dartisan.dart db:transfer --from=sqlite --to=pgsql://app:secret@db.internal:5432/app
dart run bin/dartisan.dart db:transfer --from=sqlite --to=pgsql --dry-run   # counts, changes nothing
```

`--from` and `--to` take a connection name (`sqlite`, `pgsql`, a
`withDatabaseConnection` name) or a URL. The `DB_*` keys configure every
built-in connection at once, so a URL is how one `.env` reaches two
databases.

- **Schema.** The target is migrated with the application's migrations
  first (`--no-migrate` when it already is). Each database gets its own
  column types rather than a translation of the source's DDL. Tables that
  no migration creates are listed and skipped, and the `migrations` ledger
  is never copied.
- **Order and atomicity.** Tables are copied parents first, following the
  target's foreign keys, in one transaction on the target. A failure
  leaves the target as it was. On PostgreSQL, foreign keys are deferred
  during the copy and checked once at the end, so rows that reference
  later rows (a category whose parent comes after it) or tables that
  reference each other copy too. Their definitions are restored before
  the commit.
- **Values.** `0`/`1` become booleans on PostgreSQL, JSON documents from
  PostgreSQL become text, and dates become Laravel's `Y-m-d H:i:s` on SQLite
  and MySQL.
- **Ids.** Rows keep their primary keys. PostgreSQL sequences continue after
  the highest copied id, so the next insert does not collide.
- **Safety.** A target table that already has rows stops the transfer
  unless `--truncate` replaces them. With `APP_ENV=production` it needs
  `--force`. Rows are read in chunks of `--chunk` (500), paged by
  primary key. `--tables=users,posts` limits the copy.

## Migrations

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#migration -->
```dart
final class CreatePostsTable extends Migration {
  const CreatePostsTable();

  @override
  String get name => '2026_01_01_000000_create_posts_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('posts', (table) {
    table.id();
    table.string('title');
    table.text('body').nullable();
    table.boolean('published').defaultTo(false);
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('posts');
}
```
<!-- /include -->

Migrations are listed in `bootstrap/migrations.dart` and recorded in
Laravel's `migrations` table (`id`, `migration`, `batch`), so a Laravel app
and a Daravel app can share one ledger. Commands: `migrate`,
`migrate:status`, `migrate:rollback`, `migrate:reset`, `migrate:fresh`,
`db:seed`. On SQLite, column changes rebuild the table safely.

## Models

Models are "hybrid active records": an attribute bag plus a static
`ModelDefinition` that replaces Laravel's magic properties.

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#model -->
```dart
final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title', 'body', 'published'],
    casts: {'published': Cast.boolean},
    scopes: {'published': (query, args) => query.where('published', true)},
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  static ModelQuery<Post> query() => definition.query();

  int get id => getAttr('id');
  String get title => getAttr('title');
  bool get published => getAttr('published');
}
```
<!-- /include -->

`dartisan make:model` writes this for you and `dartisan model:sync`
regenerates the typed accessors from the table. Relations (`HasOne`,
`HasMany`, `BelongsTo`, `BelongsToMany`, `HasManyThrough` and the
[polymorphic ones](orm.md#polymorphic-relations)) are declared in
`relations:` and eager loaded with `with_([...])` (`with` is a reserved
word in Dart). Soft deletes, observers, model events, global scopes,
`withCount` and (nested) `whereHas` work as in Eloquent.

`ModelDefinition.morphClass` is the Laravel class name of the model
(`App\Models\Post` by default). It is stored in polymorphic columns such as
`personal_access_tokens.tokenable_type`, unless `Relation.morphMap` gives
the model an alias, and used in
`No query results for model [App\Models\Post] 1`.

## Querying

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#query -->
```dart
await Post.query().create({'title': 'Hello', 'published': true});
await DB.table('posts').insert({'title': 'Draft'});

final published = await Post.query()
    .where('published', true)
    .orderByDesc('id')
    .get();
final titles = await DB.table('posts').orderBy('id').pluck('title');
final count = await Post.query().scope('published').count();

await DB.transaction(() async {
  final post = await Post.query().findOrFail(1);
  await post.update({'title': 'Hello, Daravel'});
});
```
<!-- /include -->

Transactions follow the zone: nested calls become savepoints, and
after-commit callbacks (`App.make<DatabaseManager>().afterCommit(...)`, used
by queued jobs and `Event.dispatchAfterCommit`) run only when the outer
transaction commits.

Dart can run several things at once inside one transaction, which PHP
cannot, so two rules keep it safe:

- Nested transactions started together (`Future.wait([DB.transaction(...),
  DB.transaction(...)])`) run one after the other, because savepoints on a
  connection form a stack. One failing rolls back only its own work.
- A query that runs after its transaction has finished (a missing `await`)
  throws a `StateError` instead of running outside the transaction.
  `await` every query inside `DB.transaction`; `dartisan lint`
  (`unawaited_in_db_transaction`) points out the ones that are not,
  including `unawaited(...)` and `.ignore()`.

## JSON columns

`->` reads and writes inside a JSON column, on every driver:

```dart
await DB.table('users').where('meta->lang', 'id').get();
await DB.table('users').orderBy('meta->lang').get();
await DB.table('users').whereJsonContains('meta->roles', 'admin').get();
await DB.table('users').where('id', 1).update({
  'meta->lang': 'en',
  'meta->flags': [1, 2],
});
```

A path holds plain keys and indexes (`items[0]->id`); anything else is an error,
as an invalid column is. An update keeps the other keys and the JSON type of the
value, also on a `NULL` column. A nested path needs its parent on PostgreSQL and
MySQL, as in Laravel; SQLite creates it.

## Vector columns

On PostgreSQL with [pgvector](https://github.com/pgvector/pgvector), a column can
hold an embedding, and queries can sort by cosine distance. The names and the SQL
are Laravel's.

```dart
await Schema.ensureVectorExtensionExists();

await Schema.create('documents', (table) {
  table.id();
  table.vector('embedding', dimensions: 1536);
  table.vectorIndex('embedding');              // HNSW, cosine
  table.tsvector('search').nullable();
});

final nearest = await Document.query()
    .whereVectorSimilarTo('embedding', queryVector, minSimilarity: 0.7)
    .limit(10)
    .get();
```

`whereVectorSimilarTo` keeps rows at least that alike, nearest first; pass
`order: false` to keep your own order. `whereVectorDistanceLessThan`,
`orderByVectorDistance` and `selectVectorDistance` are the parts of it. `Cast.vector`
reads the column as a `List<double>`.

SQLite stores these columns as text and leaves the index out, so a migration still
runs in tests, but distance queries throw there. On MySQL and MariaDB, `vector` adds
the column only: indexes and distance queries are not supported yet.

## Query errors

A query the database refuses throws `QueryException`, with `sql`,
`bindings`, `connectionName` and the driver's own error in `previous`. A
row refused by a unique index or primary key throws its subclass
`UniqueConstraintViolationException` (SQLite, PostgreSQL `23505`,
MySQL/MariaDB `1062`), as in Laravel, and like Laravel it is a 500 unless
caught. The `unique` rule answers 422 before the insert; this exception
covers two requests that both pass that check:

```dart
try {
  await User.query().create({'email': email, 'name': name});
} on UniqueConstraintViolationException {
  throw ValidationException.withMessages({
    'email': 'The email has already been taken.',
  });
}
```

`createOrFirst(attributes, values)` creates the row or, when another
request created it first, returns that one; `firstOrCreate` and
`updateOrCreate` go through it, as in Laravel 12. Inside a transaction the
insert runs in a savepoint, so a refused insert does not abort the
transaction (PostgreSQL would otherwise).

Unlike Laravel's, the message keeps the `?` placeholders and only the first
line of the driver's error, so binding values (a password hash, an email)
stay out of logs; the database's own words may still name a conflicting
value (MySQL's `Duplicate entry`, PostgreSQL's detail).

## Retrying transactions

```dart
await DB.transaction(() async {
  // ...
}, attempts: 5);
```

Deadlocks and serialization failures run the whole callback again. Between
attempts it waits a random 2 to 250 ms, holding no connection, so isolates that
collided do not collide again. A frozen test clock retries at once.

## Listening to queries

`DB.listen((QueryExecuted query) { ... })` is called after every query of
the builder, the ORM, raw SQL and migrations, with its SQL, bindings,
duration and connection. `query.poolWait` is the time it waited for a
connection, apart from `query.time`: a high value means the pool is too small,
not that the database is slow. It is zero inside a transaction, which holds its
connection, and on SQLite. For example, to log slow queries:

```dart
DB.listen((query) {
  if (query.time > const Duration(milliseconds: 100)) {
    Log.warning('Slow query', {'sql': query.sql, 'ms': query.time.inMilliseconds});
  }
});
```

Without listeners, queries are neither timed nor reported.

For a time budget rather than single slow queries, Laravel's
`whenQueryingForLongerThan` adds up the queries of each request, job or
command and calls the handler once when the total passes the threshold:

```dart
DB.whenQueryingForLongerThan(const Duration(milliseconds: 500), (query) {
  Log.warning('Request spent over 500 ms in queries',
      {'total_ms': DB.totalQueryDuration.inMilliseconds});
});
```

`DB.withQueryCount` runs a callback and returns its result with the queries
it ran, which turns an N+1 into a failing test:

```dart
final (users, count, queries) = await DB.withQueryCount(
  () => User.query().with_('posts').get(),
);
expect(count, 2); // users, then every post in one query
```

## Dates in queries

`whereDate`, `whereYear`, `whereMonth` and `whereDay` compare a part of a
date column. Laravel 11's shortcuts compare with the current time, read from
`Clock` (so `freezeTime()` applies), and take a column or a list:

| Method | Condition |
| :-- | :-- |
| `wherePast` / `whereNowOrPast` | before / at or before now |
| `whereFuture` / `whereNowOrFuture` | after / at or after now |
| `whereToday` | the date is today |
| `whereBeforeToday` / `whereTodayOrBefore` | the date is before / at most today |
| `whereAfterToday` / `whereTodayOrAfter` | the date is after / at least today |

Each has an `orWhere…` form, on `DB.table(...)` and on model queries.

## Pagination

`paginate()`, `simplePaginate()` and `cursorPaginate()` read the page (or
cursor) and the absolute path from the current request, like Laravel, and
serialize to Laravel's exact JSON: the same keys in the same order, `links`
with Laravel's sliding window and `page` numbers, `current_page_url` for
simple pagination, and cursors encoded like Laravel's `Cursor::encode()` so
a cursor issued by either framework works in the other. Use
`withQueryString()` or `appends({...})` to keep extra query parameters.
