# Database

`DB_CONNECTION` selects SQLite (`sqlite`, the default), PostgreSQL (`pgsql`),
MySQL (`mysql`) or MariaDB (`mariadb`). MySQL and MariaDB come from
`package:daravel_mysql`, which new projects register in `bootstrap/app.dart`:

```dart
Application.configure(basePath: '.')
    .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
    .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
```

On MySQL, results read as in Laravel (`TINYINT(1)` as `0`/`1`, `DECIMAL` and
`JSON` as strings, dates as `Y-m-d H:i:s`), and the session time zone is the
server's unless `DB_TIMEZONE` is set, so `TIMESTAMP` columns read the same
from both frameworks. MySQL 8.4 and MariaDB 11 run in CI on every commit.
Every query is built by a grammar with bound values; identifiers are quoted.

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

## Listening to queries

`DB.listen((QueryExecuted query) { ... })` is called after every query of
the builder, the ORM, raw SQL and migrations, with its SQL, bindings,
duration and connection, for example to log slow queries:

```dart
DB.listen((query) {
  if (query.time > const Duration(milliseconds: 100)) {
    Log.warning('Slow query', {'sql': query.sql, 'ms': query.time.inMilliseconds});
  }
});
```

Without listeners, queries are not wrapped and cost nothing extra.

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
