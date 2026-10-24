# Database

SQLite and PostgreSQL are supported at runtime (`DB_CONNECTION=sqlite` or
`pgsql`); the MySQL grammar exists but its driver is planned for Tier 2.
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
`HasMany`, `BelongsTo`, `BelongsToMany`, `HasManyThrough`) are declared in
`relations:` and eager loaded with `with_([...])` (`with` is a reserved
word in Dart). Soft deletes, observers, model events, global scopes,
`withCount` and `whereHas` work as in Eloquent.

`ModelDefinition.morphClass` is the Laravel class name of the model
(`App\Models\Post` by default). It is stored in polymorphic columns such as
`personal_access_tokens.tokenable_type` and used in
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

## Pagination

`paginate()`, `simplePaginate()` and `cursorPaginate()` read the page (or
cursor) and the absolute path from the current request, like Laravel, and
serialize to Laravel's exact JSON: the same keys in the same order, `links`
with Laravel's sliding window and `page` numbers, `current_page_url` for
simple pagination, and cursors encoded like Laravel's `Cursor::encode()` so
a cursor issued by either framework works in the other. Use
`withQueryString()` or `appends({...})` to keep extra query parameters.
