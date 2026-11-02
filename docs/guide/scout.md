# Search (daravel_scout)

`daravel_scout` is Laravel Scout's `database` engine: the search runs on the
model's own table, with no index to keep in sync. On PostgreSQL with pgvector, or
on MariaDB 11.7 or newer, it also searches by meaning.

```bash
dart pub add daravel_scout
```

## Searching

Mix `Searchable` into a model and name the columns to search. A fresh model has
no attributes, so `toSearchableArray` must list them, as in Scout.

```dart
import 'package:daravel_scout/daravel_scout.dart';

final class Post extends Model with Searchable {
  // ... definition and accessors

  @override
  Map<String, Object?> toSearchableArray() => {'title': null, 'body': null};

  @override
  List<String> get searchUsingFullText => const ['body'];

  @override
  List<String> get searchUsingPrefix => const ['title'];
}

final posts = await Scout.search(Post.definition, 'laravel')
    .where('published', true)
    .take(10)
    .get();
```

Each column matches with `LIKE` (`ILIKE` on PostgreSQL), `query%` for a prefix
column. A numeric query also matches the key. Results come newest first; with full
text columns on PostgreSQL, by relevance. `whereIn`, `whereNotIn`, `orderBy`,
`first`, `keys`, `paginate`, and `constrain` for more of the database query work as
in Scout.

`searchUsingFullText` is Scout's `#[SearchUsingFullText]`: PostgreSQL `tsvector`
and MySQL or MariaDB `MATCH`. `fullTextOptions` sets the `language` and the
`mode`. SQLite has no full text search, so a full text column throws there.

## Search by meaning

Set the vector column and what to embed, and give Scout a function that turns
texts into vectors. Scout uses `laravel/ai` for that; here it is yours to plug in.

```dart
@override
String? get searchableEmbeddingColumn => 'embedding';

@override
Object? toSearchableEmbedding() => body;   // or a List<num> you already have

Scout.embedder = (texts) => myEmbeddingService.embed(texts);
await Scout.makeSearchable(posts);         // writes the vectors

final similar = await Scout.search(Post.definition, 'deploying apps')
    .semantic(0.7)
    .get();

final both = await Scout.search(Post.definition, 'deploying apps')
    .hybrid(textWeight: 1, semanticWeight: 2)
    .get();
```

`semantic` keeps rows at least that alike (0.6 by default), nearest first.
`hybrid` fuses the text and the meaning ranks with reciprocal rank fusion, as Scout
does. Neither combines with `orderBy`. The column comes from `table.vector`
([Database](database.md#vector-columns)); on SQLite these throw.
