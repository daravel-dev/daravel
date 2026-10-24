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

## Relations

`HasOne`, `HasMany`, `BelongsTo`, `BelongsToMany` (with `withPivot` and
`withTimestamps`) and `HasManyThrough`.

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

## Not yet

Polymorphic relations (`morphTo`, `morphMany`) and nested `whereHas`
(`'posts.comments'`) are planned.
