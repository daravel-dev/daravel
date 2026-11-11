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

## Rerank

`hybrid(rerank: true)` orders the first 1 000 fused models by their cosine
similarity to the query's vector, computed in Dart with `Float32x4` (four
lanes at a time, a scalar loop for the rest) on the vectors the database
already returned with the models. Nothing else is queried and nothing is kept
in memory, so keep the embedding column selected in `constrain()`; models
without a vector follow in fused order.

The `Float32x4` lanes sum in float32 and the scalar loop in doubles, so a
score can differ from a double-precision cosine by up to about 1e-5 (3 072
dimensions). Two models whose scores are closer than that are a near-tie
whose order is not guaranteed; equal scores keep their fused order.

`bench/bin/scout_rerank.dart`, 1 000 candidates, measured on 2026-11-06
(Dart 3.13.4 AOT, Windows x64):

| Dimensions | Scalar cosine | `Float32x4` cosine | Rerank from MariaDB bytes | Rerank from pgvector binary | Rerank from pgvector text |
| --: | --: | --: | --: | --: | --: |
| 1 536 | 3.5 ms | 1.1 ms (3.2×) | 3.0 ms | 12 ms | 115 ms |
| 3 072 | 7.0 ms | 2.1 ms (3.3×) | 5.1 ms | 22 ms | 224 ms |

The cosine columns score 1 000 vectors already in `Float32List`s; the rerank
columns add reading the driver's values, which costs more than the cosine
itself, most of all for pgvector's text form.
