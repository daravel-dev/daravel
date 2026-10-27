# ORM

Models follow Eloquent's API. Because Dart has no magic properties, each
model has a static `ModelDefinition` that describes its table, attributes
and relations; [Database](database.md) shows a complete model and the query
builder.

## Definition

```dart
final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password', 'remember_token'],
    casts: {'email_verified_at': Cast.dateTime, 'settings': Cast.json},
    softDeletes: true,
    relations: {
      'posts': () => HasMany<Post>(() => Post.definition, foreignKey: 'user_id'),
      'roles': () => BelongsToMany<Role>(
        () => Role.definition,
        pivotTable: 'role_user',
        foreignPivotKey: 'user_id',
        relatedPivotKey: 'role_id',
      ),
    },
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}
```

The static is `definition` and the instance getter `modelDefinition`
because Dart forbids a static and an instance member with the same name.
Keep the explicit `ModelDefinition<User>` type and write relations as
functions: models that refer to each other would otherwise form an
inference cycle.

Other options: `primaryKey`, `keyType` (auto-increment, UUID, ULID or string),
`connection`, `guarded`, `visible`, `appends`, `timestamps` and the
`createdAt` / `updatedAt` / `deletedAt` column names, `perPage`, `touches`,
`withRelations` (Eloquent's `$with`) and `morphClass` (the Laravel class
name stored in polymorphic columns, `App\Models\User` by default).

## Attributes

Casts: `Cast.integer`, `decimal`, `boolean`, `string`, `dateTime`, `date`,
`json`, `Cast.enumeration(MyEnum.values)` and `Cast.custom(...)`.
`accessors:` and `mutators:` replace Laravel's attribute methods, and
`dartisan model:sync` writes typed getters and setters from the table, so
`user.email` is a `String` checked by the compiler.

## Model registry

`bootstrap/models.dart` lists the application's models, the way the other
registries list migrations and jobs (Daravel discovers nothing by
reflection):

```dart
final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  // <dartisan:entries>
  User.definition,
  Post.definition,
  // </dartisan:entries>
];
```

`createApp` passes it to `.withModels(models)`, and `dartisan make:model`
adds new models to it. `dartisan model:show Post [--json]` (Laravel 11's
`model:show`) prints the model's table, attributes with their type, cast,
fillable and hidden flags, and its relations; `dartisan mcp:serve` gives AI
agents the same data. Once the file exists, `dartisan lint` reports models
in `lib/app/models` that it leaves out.

Projects created before 1.3 can add the file by hand (copy the block above,
with one entry per model) and the `.withModels(models)` call; until then
everything else keeps working.

## Relations

`HasOne`, `HasMany`, `BelongsTo`, `BelongsToMany` (with `withPivot` and
`withTimestamps`), `HasManyThrough`, `HasOneThrough`, and the polymorphic `MorphOne`,
`MorphMany`, `MorphTo`, `MorphToMany` and `MorphedByMany`
(see [Polymorphic relations](#polymorphic-relations)).

```dart
final users = await User.query()
    .with_(['posts', 'roles'])      // eager loading; `with` is reserved in Dart
    .withCount('posts')
    .whereHas('posts', (q) => q.where('published', true))
    .paginate();

final posts = users.items.first.related<List<Post>>('posts');
final drafts = await user.relatedQuery<Post>('posts').where('published', false).get();

await user.attach('roles', [1, 2]);
await user.sync('roles', [2, 3]);
await user.detach('roles', [3]);
```

`load` and `loadMissing` load relations onto models you already have.
`Model.preventLazyLoading` turns an unloaded relation into an error, which
catches N+1 queries in tests.

### Eager loading specific columns

As in Laravel, `relation:column,column` reads only those columns of a
relation, at any depth, and as a map key next to a constraint:

```dart
await Post.query().with_(['user:id,name', 'comments:id,post_id,body']).get();
await User.query().with_(['posts:title', 'posts.comments:body']).get();
await Post.query().with_({
  'comments:id,post_id,body': (q) => q.latest().limit(5),
}).get();
```

Where Laravel leaves a relation empty when the selection forgets the key it
matches on (`with('user:name')`), Daravel adds it: the owner key of a
`BelongsTo`, the foreign key of a `HasMany`, the keys the next level of a
nested load reads (`posts.id` above), and the foreign keys a root
`select([...])` needs for its relations. The pivot columns of a
`BelongsToMany` and the intermediate key of a `HasManyThrough` stay
selected, and their columns are qualified, so `id` is never ambiguous.

### Nested existence queries

`whereHas`, `orWhereHas`, `has`, `whereDoesntHave`, `orWhereDoesntHave`,
`doesntHave` and `withWhereHas` accept nested relations, at any depth. Each
level becomes an `EXISTS` inside the previous one, the constraint applies to
the last, and soft deletes and global scopes apply at every level:

```dart
// Users with at least one approved comment on one of their posts.
final users = await User.query()
    .whereHas('posts.comments', (q) => q.where('approved', true))
    .get();
```

A relation to the same model (`Category` with `parent` and `children`, users
following users) works too: the inner table gets an alias, as Laravel's
`laravel_reserved_N`, so `whereHas('children')` compares a child with its
outer parent rather than with itself.

### Relation aggregates

`withCount`, `withSum`, `withAvg`, `withMin`, `withMax` and `withExists` add
a column per relation, named as in Laravel (`posts_count`,
`orders_sum_total`, `orders_exists`); `'orders as paid_orders'` picks the
name, and a map adds a constraint:

```dart
final users = await User.query()
    .withCount('posts')
    .withSum('orders', 'total')
    .withMax({'orders': (ModelQuery<Model> q) => q.where('paid', true)}, 'total')
    .withExists('orders')
    .get();
```

`*_exists` reads as a `bool`. Sums and averages come back as the driver
returns them: numbers on SQLite, strings for `DECIMAL`/`numeric` results on
MySQL and PostgreSQL, as with Laravel's PDO.

## Polymorphic relations

A polymorphic relation lets one table belong to several models: comments on
posts and on videos, images of users and of products, tags shared by
everything. The child row stores the owner's type in `{name}_type` and its
key in `{name}_id`, exactly as Laravel stores them, so both frameworks can
read the same rows.

```dart
// Migration
schema.create('comments', (table) {
  table.id();
  table.morphs('commentable'); // commentable_type, commentable_id + index
  table.text('body');
});

// Post (and Video, the same way)
'comments': () => MorphMany<Comment>(() => Comment.definition, morphName: 'commentable'),
'image': () => MorphOne<Image>(() => Image.definition, morphName: 'imageable'),
'tags': () => MorphToMany<Tag>(() => Tag.definition, morphName: 'taggable', relatedPivotKey: 'tag_id'),

// Comment: the owner, a Post or a Video
'commentable': () => MorphTo(types: [() => Post.definition, () => Video.definition]),

// Tag: the inverse of morphToMany
'posts': () => MorphedByMany<Post>(() => Post.definition, morphName: 'taggable', foreignPivotKey: 'tag_id'),
```

- `MorphMany` / `MorphOne` work like `HasMany` / `HasOne`, filtered on the
  owner's type: eager loading, `relatedQuery`, `whereHas`, `withCount` and
  `create(parent, db, attributes)`, which fills both morph columns.
- `MorphTo` loads each row's owner, one query per stored type when eager
  loading, and nested relations (`with_(['commentable.author'])`) load per
  type. `associate(child, owner)` and `dissociate(child)` set the columns;
  `touches: ['commentable']` updates the owner's timestamp.
- `MorphToMany` / `MorphedByMany` work like `BelongsToMany` (`attach`,
  `detach`, `sync`, `withPivot`) with the type column on the pivot table
  (`{name}s` by default, `taggables` here).
- `whereHasMorph('commentable', [Post.definition], (q, type) => ...)`,
  `whereDoesntHaveMorph` and their `orWhere*` forms query the owner. On a
  `MorphTo`, `whereHas` and `whereDoesntHave` check every type the relation
  knows.

The stored type is the model's `morphClass` (`App\Models\Post` by default,
like Laravel's class name). Register aliases as in Laravel; rows that still
hold the class name keep resolving:

```dart
Relation.morphMap({'post': () => Post.definition, 'video': () => Video.definition});
Relation.enforceMorphMap({...}); // every polymorphic model must then have an alias
```

Dart has no reflection, so a `MorphTo` cannot turn a stored class name into
a model on its own: every possible owner must be listed in `types:` or in
the morph map. For the same reason, `whereHas` on a `MorphTo` checks the
listed types, where Laravel reads the distinct types from the table.

## Scopes, soft deletes and events

- Local scopes (`scopes:`) are called with `query.scope('published')`;
  `globalScopes:` apply to every query.
- With `softDeletes: true`, `delete()` sets `deleted_at`, queries skip
  deleted rows, and `withTrashed()`, `onlyTrashed()`, `restore()` and
  `forceDelete()` work as in Laravel.
- Observers (`observers:`) receive `creating`, `created`, `updating`,
  `updated`, `saving`, `saved`, `deleting`, `deleted`, `restoring`,
  `restored` and the force-delete events; returning `false` from a `*ing`
  hook cancels the operation.
