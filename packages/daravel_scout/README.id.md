<!-- source: README.md sha256:42df7d0605d0 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_scout

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_scout/README.md) · Bahasa Indonesia

Laravel Scout untuk [Daravel](https://daravel.dev), dengan engine database:
pencarian berjalan di tabel model itu sendiri dengan `LIKE` dan full text search,
serta `semantic()` dan `hybrid()` mencari berdasarkan makna di PostgreSQL dengan
pgvector atau di MariaDB.

```dart
final class Post extends Model with Searchable {
  // ...
  @override
  Map<String, Object?> toSearchableArray() => {'title': null, 'body': null};
}

final posts = await Scout.search(Post.definition, 'laravel').take(10).get();
```

Lihat [panduannya](https://daravel.dev/id/scout.html).
