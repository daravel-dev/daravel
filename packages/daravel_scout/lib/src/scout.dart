import 'dart:async';

import 'package:daravel/daravel.dart';

import 'rerank.dart';
import 'searchable.dart';

/// Scout's `ScoutException`: a search that cannot run as asked.
final class ScoutException implements Exception {
  /// A search error with [message].
  const ScoutException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'ScoutException: $message';
}

/// Turns texts into vectors for `semantic()` and `hybrid()`, as `laravel/ai`'s
/// `Embeddings` does for Scout.
typedef ScoutEmbedder = Future<List<List<double>>> Function(List<String> texts);

/// Laravel Scout on the database engine.
///
/// ```dart
/// final posts = await Scout.search(Post.definition, 'laravel')
///     .where('published', true)
///     .take(10)
///     .get();
/// ```
abstract final class Scout {
  /// Makes the vectors for `semantic()`, `hybrid()` and [makeSearchable].
  static ScoutEmbedder? embedder;

  /// Scout's `Model::search($query)`.
  static ScoutBuilder<T> search<T extends Model>(
    ModelDefinition<T> definition, [
    String query = '',
  ]) => ScoutBuilder<T>._(definition, query);

  /// Scout's `searchable()` on the database engine: the rows are already
  /// there, so this only writes the vectors of models that have an embedding
  /// column.
  static Future<void> makeSearchable(Iterable<Model> models) async {
    final list = models.toList();
    if (list.isEmpty) {
      return;
    }
    final first = _searchable(list.first);
    final column = first.searchableEmbeddingColumn;
    if (column == null) {
      return;
    }
    final definition = first.modelDefinition;
    final dialect = DB.manager.dialectOf(definition.connection);
    for (var start = 0; start < list.length; start += 100) {
      final batch = list.sublist(start, (start + 100).clamp(0, list.length));
      final vectors = List<List<double>?>.filled(batch.length, null);
      final texts = <int, String>{};
      for (var i = 0; i < batch.length; i++) {
        switch (_searchable(batch[i]).toSearchableEmbedding()) {
          case final List<num> vector:
            vectors[i] = [for (final n in vector) n.toDouble()];
          case final String text when text.trim().isNotEmpty:
            texts[i] = text;
          default:
            throw const ScoutException(
              'toSearchableEmbedding must give a non-empty string or a vector.',
            );
        }
      }
      if (texts.isNotEmpty) {
        final made = await _embed(texts.values.toList());
        var position = 0;
        for (final index in texts.keys) {
          vectors[index] = made[position++];
        }
      }
      for (var i = 0; i < batch.length; i++) {
        final model = batch[i];
        await DB
            .table(definition.table, connection: definition.connection)
            .where(definition.primaryKey, model.key)
            .update({column: const VectorCast().setFor(vectors[i], dialect)});
        model.setAttr(column, vectors[i]);
      }
    }
  }

  static Future<List<List<double>>> _embed(List<String> texts) async {
    final make = embedder;
    if (make == null) {
      throw const ScoutException(
        'Semantic search needs Scout.embedder, a function from texts to vectors.',
      );
    }
    return make(texts);
  }

  /// Scout's reciprocal rank fusion: each list adds `weight / (60 + rank)` to
  /// a model, and ties go by key.
  static List<M> fuse<M extends Model>(
    List<M> text,
    List<M> semantic, {
    num textWeight = 1,
    num semanticWeight = 1,
  }) {
    final scores = <String, double>{};
    final models = <String, M>{};
    for (final (ranked, weight) in [
      (text, textWeight),
      (semantic, semanticWeight),
    ]) {
      final seen = <String>{};
      for (var position = 0; position < ranked.length; position++) {
        final model = ranked[position];
        final key = '${model.key}';
        if (!seen.add(key)) {
          continue;
        }
        models[key] = model;
        scores[key] = (scores[key] ?? 0) + weight / (60 + position + 1);
      }
    }
    final keys = scores.keys.toList()
      ..sort((a, b) {
        final byScore = scores[b]!.compareTo(scores[a]!);
        return byScore != 0 ? byScore : a.compareTo(b);
      });
    return [for (final key in keys) models[key]!];
  }
}

Searchable _searchable(Model model) => model is Searchable
    ? model
    : throw ArgumentError('${model.runtimeType} does not mix in Searchable.');

/// Scout's `Builder`, run by the database engine.
final class ScoutBuilder<T extends Model> {
  ScoutBuilder._(this.definition, this.query);

  /// The searched model's definition.
  final ModelDefinition<T> definition;

  /// The search text.
  final String query;

  final Map<String, Object?> _wheres = {};
  final Map<String, List<Object?>> _whereIns = {};
  final Map<String, List<Object?>> _whereNotIns = {};
  final List<(String, String)> _orders = [];
  int? _limit;
  bool _semantic = false;
  double? _minimumSimilarity;
  (num, num)? _hybrid;
  bool _rerank = false;
  void Function(ModelQuery<T> query)? _callback;

  late final Searchable _model = _searchable(definition.factory());

  /// Only models whose [field] equals [value].
  ScoutBuilder<T> where(String field, Object? value) {
    _wheres[field] = value;
    return this;
  }

  /// Only models whose [field] is one of [values].
  ScoutBuilder<T> whereIn(String field, List<Object?> values) {
    _whereIns[field] = values;
    return this;
  }

  /// Only models whose [field] is none of [values].
  ScoutBuilder<T> whereNotIn(String field, List<Object?> values) {
    _whereNotIns[field] = values;
    return this;
  }

  /// At most [limit] models.
  ScoutBuilder<T> take(int limit) {
    _limit = limit;
    return this;
  }

  /// Orders by [column] instead of relevance.
  ScoutBuilder<T> orderBy(String column, [String direction = 'asc']) {
    _orders.add((column, direction.toLowerCase()));
    return this;
  }

  /// Orders by [column], descending.
  ScoutBuilder<T> orderByDesc(String column) => orderBy(column, 'desc');

  /// Scout's `query()`: more constraints on the database query.
  ScoutBuilder<T> constrain(void Function(ModelQuery<T> query) callback) {
    _callback = callback;
    return this;
  }

  /// Nearest by meaning first, at least [minSimilarity] alike (0.6).
  ScoutBuilder<T> semantic([double? minSimilarity]) {
    if (query.trim().isEmpty) {
      throw const ScoutException(
        'Semantic searches require a non-empty query.',
      );
    }
    _semantic = true;
    _minimumSimilarity = minSimilarity;
    _hybrid = null;
    return this;
  }

  /// Text and meaning together, fused by rank.
  ///
  /// With [rerank], the first 1 000 fused models are then ordered by their
  /// cosine similarity to the query's vector, computed here (`Float32x4`) on
  /// the vectors the database already returned with them: the embedding
  /// column must stay selected, and models without a vector follow in fused
  /// order.
  ScoutBuilder<T> hybrid({
    num textWeight = 1,
    num semanticWeight = 1,
    double? minSimilarity,
    bool rerank = false,
  }) {
    if (query.trim().isEmpty) {
      throw const ScoutException('Hybrid searches require a non-empty query.');
    }
    if (textWeight <= 0 || semanticWeight <= 0) {
      throw const ScoutException(
        'Hybrid search weights must be positive numbers.',
      );
    }
    _semantic = false;
    _minimumSimilarity = minSimilarity;
    _hybrid = (textWeight, semanticWeight);
    _rerank = rerank;
    return this;
  }

  /// The matching models.
  Future<ModelCollection<T>> get() async {
    if (_hybrid != null) {
      return ModelCollection<T>(await _fused((_limit ?? 1000).clamp(0, 1000)));
    }
    return (await _query()).get();
  }

  /// The first matching model, or null.
  Future<T?> first() async {
    _limit = 1;
    final results = await get();
    return results.isEmpty ? null : results.first;
  }

  /// The keys of the results.
  Future<List<Object?>> keys() async => [for (final m in await get()) m.key];

  /// A page of the matching models, in Laravel's paginator JSON.
  Future<LengthAwarePaginator<T>> paginate({
    int perPage = 15,
    int page = 1,
  }) async {
    if (_hybrid == null) {
      return (await _query(paginating: true))
          .paginate(perPage: perPage, page: page);
    }
    final all = await _fused(1000);
    final from = ((page - 1) * perPage).clamp(0, all.length);
    return LengthAwarePaginator<T>(
      items: all.sublist(from, (from + perPage).clamp(0, all.length)),
      total: all.length,
      perPage: perPage,
      currentPage: page,
    );
  }

  String get _table => definition.table;

  String _qualify(String column) =>
      column.contains('.') ? column : '$_table.$column';

  SqlDialect get _dialect => DB.manager.dialectOf(definition.connection);

  Future<ModelQuery<T>> _query({bool paginating = false}) async {
    final query = definition.query();
    if (_semantic) {
      await _addSemantic(query);
      if (!paginating && _limit != null) {
        query.take(_limit!);
      }
      return _constrained(query);
    }
    _addText(query);
    if (!paginating && _limit != null) {
      query.take(_limit!);
    }
    for (final (column, direction) in _orders) {
      query.orderBy(column, direction);
    }
    final fullText = _without(_model.searchUsingFullText);
    if (fullText.isEmpty) {
      query.orderBy(_qualify(definition.primaryKey), 'desc');
    } else if (_dialect == .postgres && _orders.isEmpty) {
      _orderByRelevance(query, fullText);
    }
    return _constrained(query);
  }

  ModelQuery<T> _constrained(ModelQuery<T> query) {
    _callback?.call(query);
    for (final MapEntry(:key, :value) in _wheres.entries) {
      query.where(key, value);
    }
    for (final MapEntry(:key, :value) in _whereIns.entries) {
      query.whereIn(key, value);
    }
    for (final MapEntry(:key, :value) in _whereNotIns.entries) {
      query.whereNotIn(key, value);
    }
    return query;
  }

  List<String> _without(Iterable<String> columns) => [
    for (final column in columns)
      if (column != _model.searchableEmbeddingColumn) column,
  ];

  void _addText(ModelQuery<T> query) {
    if (this.query.trim().isEmpty) {
      return;
    }
    final columns = _without(_model.toSearchableArray().keys);
    final prefix = _without(_model.searchUsingPrefix);
    final fullText = _without(_model.searchUsingFullText);
    final key = definition.primaryKey;
    final searchKey =
        RegExp(r'^\d+$').hasMatch(this.query) &&
        int.tryParse(this.query) != null &&
        definition.keyType == .autoInt &&
        columns.contains(key);
    final like = _dialect == .postgres ? 'ILIKE' : 'LIKE';
    final text = this.query;
    query.builder.where((QueryBuilder group) {
      if (searchKey) {
        group.orWhere(_qualify(key), int.parse(text));
      }
      for (final column in columns) {
        if (fullText.contains(column) || (searchKey && column == key)) {
          continue;
        }
        group.orWhere(
          _qualify(column),
          like,
          prefix.contains(column) ? '$text%' : '%$text%',
        );
      }
      if (fullText.isNotEmpty) {
        final (sql, bindings) = _fullText(fullText);
        group.orWhereRaw(sql, bindings);
      }
    });
  }

  String get _language => _model.fullTextOptions['language'] ?? 'english';

  String get _tsquery => switch (_model.fullTextOptions['mode']) {
    'phrase' => 'phraseto_tsquery',
    'websearch' => 'websearch_to_tsquery',
    _ => 'plainto_tsquery',
  };

  /// Laravel's `whereFullText` for the dialect.
  (String, List<Object?>) _fullText(List<String> columns) {
    final grammar = DB.manager.grammarFor(definition.connection);
    final wrapped = [for (final c in columns) grammar.wrap(_qualify(c))];
    switch (_dialect) {
      case .postgres:
        final vectors = [
          for (final c in wrapped) 'to_tsvector(?::regconfig, $c)',
        ].join(' || ');
        return (
          '($vectors) @@ $_tsquery(?::regconfig, ?)',
          [for (final _ in wrapped) _language, _language, query],
        );
      case .mysql || .mariadb:
        final mode = _model.fullTextOptions['mode'] == 'boolean'
            ? 'boolean mode'
            : 'natural language mode';
        return ('match (${wrapped.join(', ')}) against (? in $mode)', [query]);
      case .sqlite:
        throw UnsupportedError(
          'This database engine does not support fulltext search operations.',
        );
    }
  }

  void _orderByRelevance(ModelQuery<T> query, List<String> columns) {
    final grammar = DB.manager.grammarFor(definition.connection);
    final vectors = [
      for (final c in columns)
        'to_tsvector(?::regconfig, ${grammar.wrap(_qualify(c))})',
    ].join(' || ');
    // As Scout: the rank's query takes no language.
    query.builder.orderByRaw('ts_rank($vectors, $_tsquery(?)) desc', [
      for (final _ in columns) _language,
      this.query,
    ]);
  }

  double get _similarity {
    final similarity = _minimumSimilarity ?? 0.6;
    if (similarity < 0 || similarity > 1) {
      throw const ScoutException(
        'The minimum similarity must be between 0 and 1.',
      );
    }
    return similarity;
  }

  String get _embeddingColumn {
    final column = _model.searchableEmbeddingColumn;
    if (column == null) {
      throw ScoutException(
        '${definition.table} has no searchableEmbeddingColumn for semantic search.',
      );
    }
    if (_dialect != .postgres && _dialect != .mariadb) {
      throw UnsupportedError('Semantic search needs PostgreSQL or MariaDB.');
    }
    return _qualify(column);
  }

  Future<void> _addSemantic(ModelQuery<T> query) async {
    final column = _embeddingColumn;
    if (_orders.isNotEmpty) {
      throw const ScoutException(
        'Database order clauses cannot be combined with semantic search.',
      );
    }
    final vector = (await Scout._embed([this.query])).single;
    query
        .whereVectorSimilarTo(
          column,
          vector,
          minSimilarity: _similarity,
          order: false,
        )
        .orderByVectorDistance(column, vector)
        .orderBy(_qualify(definition.primaryKey));
  }

  Future<List<T>> _fused(int limit) async {
    if (_orders.isNotEmpty) {
      throw const ScoutException(
        'Database order clauses cannot be combined with hybrid search.',
      );
    }
    if (limit <= 0) {
      return const [];
    }
    final column = _embeddingColumn;
    final vector = (await Scout._embed([query])).single;
    final text = definition.query();
    _addText(text);
    text.take(1000);
    final fullText = _without(_model.searchUsingFullText);
    if (fullText.isEmpty) {
      text.orderBy(_qualify(definition.primaryKey), 'desc');
    } else if (_dialect == .postgres) {
      _orderByRelevance(text, fullText);
      text.orderBy(_qualify(definition.primaryKey));
    }
    final semantic = definition.query()
      ..whereVectorSimilarTo(
        column,
        vector,
        minSimilarity: _similarity,
        order: false,
      )
      ..orderByVectorDistance(column, vector)
      ..orderBy(_qualify(definition.primaryKey))
      ..take(1000);
    final (weightText, weightSemantic) = _hybrid!;
    final fused = Scout.fuse(
      (await _constrained(text).get()).toList(),
      (await _constrained(semantic).get()).toList(),
      textWeight: weightText,
      semanticWeight: weightSemantic,
    );
    final ranked = _rerank
        ? rerankByCosine(
            fused.take(1000).toList(),
            vector,
            // The row's key, without a table prefix.
            _model.searchableEmbeddingColumn!.split('.').last,
          )
        : fused;
    return ranked.take(limit).toList();
  }
}
