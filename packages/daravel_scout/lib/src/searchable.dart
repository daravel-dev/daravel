import 'package:daravel/daravel.dart';

/// Laravel Scout's `Searchable`, for the database engine: the search runs on
/// the model's own table, as Scout's `database` driver does.
///
/// ```dart
/// final class Post extends Model with Searchable {
///   // ...
///   @override
///   Map<String, Object?> toSearchableArray() => {'title': '', 'body': ''};
///
///   @override
///   List<String> get searchUsingFullText => const ['body'];
/// }
/// ```
base mixin Searchable on Model {
  /// The columns searched: the keys matter, as in Scout's database engine.
  /// A fresh model has no attributes, so override this.
  Map<String, Object?> toSearchableArray() => attributes;

  /// Scout's `#[SearchUsingFullText]`: these columns use the database's full
  /// text search instead of `LIKE`. Not on SQLite.
  List<String> get searchUsingFullText => const [];

  /// Scout's `#[SearchUsingPrefix]`: `query%` instead of `%query%`.
  List<String> get searchUsingPrefix => const [];

  /// Options of the full text search: `language` (PostgreSQL, `english` by
  /// default) and `mode` (`phrase`, `websearch`, or `boolean` on MySQL).
  Map<String, String> get fullTextOptions => const {};

  /// The vector column for `semantic()` and `hybrid()`, `embedding` in Scout;
  /// null turns them off for this model.
  String? get searchableEmbeddingColumn => null;

  /// Scout's `toSearchableEmbedding`: the text to embed, or the vector itself
  /// as a `List<num>`.
  Object? toSearchableEmbedding() => null;
}
