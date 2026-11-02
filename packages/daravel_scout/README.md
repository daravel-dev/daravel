<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_scout

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_scout/README.id.md)

Laravel Scout for [Daravel](https://daravel.dev), on the database engine: the
search runs on the model's own table with `LIKE` and full text search, and
`semantic()` and `hybrid()` search by meaning on PostgreSQL with pgvector or on
MariaDB.

```dart
final class Post extends Model with Searchable {
  // ...
  @override
  Map<String, Object?> toSearchableArray() => {'title': null, 'body': null};
}

final posts = await Scout.search(Post.definition, 'laravel').take(10).get();
```

See the [guide](https://daravel.dev/scout.html).
