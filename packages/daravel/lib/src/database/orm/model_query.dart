import 'dart:async';

import '../../foundation/clock.dart';

import '../../foundation/container.dart';
import '../database_manager.dart';
import '../query/paginator.dart';
import '../query/query_ast.dart';
import '../query/query_builder.dart';
import '../query/query_grammar.dart';
import '../query_executor.dart';
import 'model.dart';
import 'model_collection.dart';
import 'model_definition.dart';
import 'observer.dart';
import 'relations.dart';

/// Model-aware query (Laravel's Eloquent `Builder`): wraps a [QueryBuilder]
/// and hydrates models, applies global scopes and soft deletes, eager loads
/// relations and offers `whereHas` / `withCount`.
final class ModelQuery<T extends Model> {
  /// A query on the model of [definition]; `Model.query()` and the
  /// generated statics create it. Relations listed in the definition's `with`
  /// are eager loaded by default.
  ModelQuery(this.definition, {DatabaseManager? db})
    : _db = db ?? Container.current.make<DatabaseManager>(),
      builder = (db ?? Container.current.make<DatabaseManager>()).table(
        definition.table,
        connection: definition.connection,
      ) {
    _with.addAll({for (final name in definition.withRelations) name: null});
  }

  /// The model's definition: table, key, casts, relations and scopes.
  final ModelDefinition<T> definition;
  final DatabaseManager _db;

  /// The underlying builder (column-level operations delegate to it).
  final QueryBuilder builder;

  final Map<String, RelationConstraint?> _with = {};
  final List<_Aggregate> _aggregates = [];
  String? _tableAlias;
  bool _withTrashed = false;
  bool _onlyTrashed = false;
  bool _withoutGlobalScopes = false;
  bool _autoload = false;
  final Set<String> _withoutNamedScopes = <String>{};
  bool _globalScopesApplied = false;

  /// The database manager this query runs on.
  DatabaseManager get database => _db;

  // ---------------------------------------------------------------------------
  // Delegated builder API (returns this for chaining)
  // ---------------------------------------------------------------------------

  /// `where('col', value)`, `where('col', '>', value)`, a map of columns to
  /// values, or a closure for a nested group, as [QueryBuilder.where].
  ModelQuery<T> where(
    Object column, [
    Object? operatorOrValue = QueryBuilder.absent,
    Object? value = QueryBuilder.absent,
  ]) {
    builder.where(column, operatorOrValue, value);
    return this;
  }

  /// [where] joined with `OR`.
  ModelQuery<T> orWhere(
    Object column, [
    Object? operatorOrValue = QueryBuilder.absent,
    Object? value = QueryBuilder.absent,
  ]) {
    builder.orWhere(column, operatorOrValue, value);
    return this;
  }

  /// Rows whose primary key is [key].
  ModelQuery<T> whereKey(Object? key) =>
      where(_qualify(definition.primaryKey), key);

  /// Rows whose primary key is not [key].
  ModelQuery<T> whereKeyNot(Object? key) =>
      where(_qualify(definition.primaryKey), '<>', key);

  /// [QueryBuilder.whereVectorSimilarTo].
  ModelQuery<T> whereVectorSimilarTo(
    String column,
    List<num> vector, {
    double minSimilarity = 0.6,
    bool order = true,
  }) {
    builder.whereVectorSimilarTo(
      column,
      vector,
      minSimilarity: minSimilarity,
      order: order,
    );
    return this;
  }

  /// [QueryBuilder.selectVector].
  ModelQuery<T> selectVector(String column) {
    builder.selectVector(column);
    return this;
  }

  /// [QueryBuilder.orderByVectorDistance].
  ModelQuery<T> orderByVectorDistance(String column, List<num> vector) {
    builder.orderByVectorDistance(column, vector);
    return this;
  }

  /// `column IN (...)` for a list, or for a subquery's rows.
  ModelQuery<T> whereIn(String column, Object values) {
    builder.whereIn(column, values);
    return this;
  }

  /// `column NOT IN (...)`.
  ModelQuery<T> whereNotIn(String column, Object values) {
    builder.whereNotIn(column, values);
    return this;
  }

  /// `column IS NULL`.
  ModelQuery<T> whereNull(String column) {
    builder.whereNull(column);
    return this;
  }

  /// `column IS NOT NULL`.
  ModelQuery<T> whereNotNull(String column) {
    builder.whereNotNull(column);
    return this;
  }

  /// `column BETWEEN from AND to`.
  ModelQuery<T> whereBetween(String column, Object? from, Object? to) {
    builder.whereBetween(column, from, to);
    return this;
  }

  /// Compares two columns: `whereColumn('updated_at', '>', 'created_at')`.
  ModelQuery<T> whereColumn(String first, String operator, String second) {
    builder.whereColumn(first, operator, second);
    return this;
  }

  /// A raw condition with `?` [bindings]. Never interpolate input into
  /// [sql].
  ModelQuery<T> whereRaw(String sql, [List<Object?> bindings = const []]) {
    builder.whereRaw(sql, bindings);
    return this;
  }

  /// `column LIKE pattern`, case-insensitive unless asked otherwise.
  ModelQuery<T> whereLike(
    String column,
    String pattern, {
    bool caseSensitive = false,
  }) {
    builder.whereLike(column, pattern, caseSensitive: caseSensitive);
    return this;
  }

  /// Compares the date part of a datetime column.
  ModelQuery<T> whereDate(
    String column,
    String operatorOrValue, [
    Object? value = QueryBuilder.absent,
  ]) {
    builder.whereDate(column, operatorOrValue, value);
    return this;
  }

  /// Compares the year of a date column.
  ModelQuery<T> whereYear(
    String column,
    Object operatorOrValue, [
    Object? value = QueryBuilder.absent,
  ]) => _on((b) => b.whereYear(column, operatorOrValue, value));

  /// Compares the month of a date column.
  ModelQuery<T> whereMonth(
    String column,
    Object operatorOrValue, [
    Object? value = QueryBuilder.absent,
  ]) => _on((b) => b.whereMonth(column, operatorOrValue, value));

  /// Compares the day of the month of a date column.
  ModelQuery<T> whereDay(
    String column,
    Object operatorOrValue, [
    Object? value = QueryBuilder.absent,
  ]) => _on((b) => b.whereDay(column, operatorOrValue, value));

  // Laravel 11's date shortcuts, against Clock.now(); [columns] is a column
  // or a list of columns.
  /// Rows whose [columns] are before now (`Clock.now()`).
  ModelQuery<T> wherePast(Object columns) =>
      _on((b) => b.wherePast(_qualifyAll(columns)));

  /// Rows whose [columns] are now or earlier.
  ModelQuery<T> whereNowOrPast(Object columns) =>
      _on((b) => b.whereNowOrPast(_qualifyAll(columns)));

  /// [wherePast] joined with `OR`.
  ModelQuery<T> orWherePast(Object columns) =>
      _on((b) => b.orWherePast(_qualifyAll(columns)));

  /// [whereNowOrPast] joined with `OR`.
  ModelQuery<T> orWhereNowOrPast(Object columns) =>
      _on((b) => b.orWhereNowOrPast(_qualifyAll(columns)));

  /// Rows whose [columns] are after now.
  ModelQuery<T> whereFuture(Object columns) =>
      _on((b) => b.whereFuture(_qualifyAll(columns)));

  /// Rows whose [columns] are now or later.
  ModelQuery<T> whereNowOrFuture(Object columns) =>
      _on((b) => b.whereNowOrFuture(_qualifyAll(columns)));

  /// [whereFuture] joined with `OR`.
  ModelQuery<T> orWhereFuture(Object columns) =>
      _on((b) => b.orWhereFuture(_qualifyAll(columns)));

  /// [whereNowOrFuture] joined with `OR`.
  ModelQuery<T> orWhereNowOrFuture(Object columns) =>
      _on((b) => b.orWhereNowOrFuture(_qualifyAll(columns)));

  /// Rows whose [columns] fall on today's date.
  ModelQuery<T> whereToday(Object columns) =>
      _on((b) => b.whereToday(_qualifyAll(columns)));

  /// Rows whose [columns] are before today.
  ModelQuery<T> whereBeforeToday(Object columns) =>
      _on((b) => b.whereBeforeToday(_qualifyAll(columns)));

  /// Rows whose [columns] are today or earlier.
  ModelQuery<T> whereTodayOrBefore(Object columns) =>
      _on((b) => b.whereTodayOrBefore(_qualifyAll(columns)));

  /// Rows whose [columns] are after today.
  ModelQuery<T> whereAfterToday(Object columns) =>
      _on((b) => b.whereAfterToday(_qualifyAll(columns)));

  /// Rows whose [columns] are today or later.
  ModelQuery<T> whereTodayOrAfter(Object columns) =>
      _on((b) => b.whereTodayOrAfter(_qualifyAll(columns)));

  /// [whereToday] joined with `OR`.
  ModelQuery<T> orWhereToday(Object columns) =>
      _on((b) => b.orWhereToday(_qualifyAll(columns)));

  /// [whereBeforeToday] joined with `OR`.
  ModelQuery<T> orWhereBeforeToday(Object columns) =>
      _on((b) => b.orWhereBeforeToday(_qualifyAll(columns)));

  /// [whereTodayOrBefore] joined with `OR`.
  ModelQuery<T> orWhereTodayOrBefore(Object columns) =>
      _on((b) => b.orWhereTodayOrBefore(_qualifyAll(columns)));

  /// [whereAfterToday] joined with `OR`.
  ModelQuery<T> orWhereAfterToday(Object columns) =>
      _on((b) => b.orWhereAfterToday(_qualifyAll(columns)));

  /// [whereTodayOrAfter] joined with `OR`.
  ModelQuery<T> orWhereTodayOrAfter(Object columns) =>
      _on((b) => b.orWhereTodayOrAfter(_qualifyAll(columns)));

  ModelQuery<T> _on(void Function(QueryBuilder builder) apply) {
    apply(builder);
    return this;
  }

  List<String> _qualifyAll(Object columns) => switch (columns) {
    final String column => [_qualify(column)],
    final Iterable<Object?> list => [for (final c in list) _qualify('$c')],
    _ => throw ArgumentError.value(columns, 'columns', 'String or List'),
  };

  /// Rows where any of [columns] matches: `whereAny(['name', 'email'],
  /// 'like', '%ana%')`.
  ModelQuery<T> whereAny(List<String> columns, String operator, Object? value) {
    builder.whereAny(columns, operator, value);
    return this;
  }

  /// Replaces the selected columns.
  ModelQuery<T> select(List<Object> columns) {
    builder.select(columns);
    return this;
  }

  /// Adds columns to the selection.
  ModelQuery<T> addSelect(List<Object> columns) {
    builder.addSelect(columns);
    return this;
  }

  /// Adds a raw select expression with `?` [bindings].
  ModelQuery<T> selectRaw(String sql, [List<Object?> bindings = const []]) {
    builder.selectRaw(sql, bindings);
    return this;
  }

  /// Selects only distinct rows.
  ModelQuery<T> distinct() {
    builder.distinct();
    return this;
  }

  /// An inner join, as [QueryBuilder.join]. Models are hydrated from every
  /// selected column, so select the model's columns when joined columns clash.
  ModelQuery<T> join(
    String table,
    Object first, [
    String? operator,
    String? second,
  ]) {
    builder.join(table, first, operator, second);
    return this;
  }

  /// A left join, as [QueryBuilder.leftJoin].
  ModelQuery<T> leftJoin(
    String table,
    Object first, [
    String? operator,
    String? second,
  ]) {
    builder.leftJoin(table, first, operator, second);
    return this;
  }

  /// `GROUP BY` [columns].
  ModelQuery<T> groupBy(List<Object> columns) {
    builder.groupBy(columns);
    return this;
  }

  /// A `HAVING` condition.
  ModelQuery<T> having(Object column, String operator, Object? value) {
    builder.having(column, operator, value);
    return this;
  }

  /// Orders by [column], `asc` or `desc`.
  ModelQuery<T> orderBy(Object column, [String direction = 'asc']) {
    builder.orderBy(column, direction);
    return this;
  }

  /// Orders by [column], descending.
  ModelQuery<T> orderByDesc(Object column) => orderBy(column, 'desc');

  /// Orders by raw SQL: [sql] is used as written, so values go in
  /// [bindings].
  ModelQuery<T> orderByRaw(String sql, [List<Object?> bindings = const []]) {
    builder.orderByRaw(sql, bindings);
    return this;
  }

  /// Newest first, by [column] or the model's `created_at` column.
  ModelQuery<T> latest([Object? column]) =>
      orderBy(column ?? definition.createdAt, 'desc');

  /// Oldest first, by [column] or the model's `created_at` column.
  ModelQuery<T> oldest([Object? column]) =>
      orderBy(column ?? definition.createdAt, 'asc');

  /// Random order.
  ModelQuery<T> inRandomOrder() {
    builder.inRandomOrder();
    return this;
  }

  /// At most [value] models.
  ModelQuery<T> limit(int value) {
    builder.limit(value);
    return this;
  }

  /// Laravel's alias of [limit].
  ModelQuery<T> take(int value) => limit(value);

  /// Skips the first [value] rows.
  ModelQuery<T> offset(int value) {
    builder.offset(value);
    return this;
  }

  /// Laravel's alias of [offset].
  ModelQuery<T> skip(int value) => offset(value);

  /// The models of page [page] (from 1), [perPage] defaulting to the
  /// model's `perPage`.
  ModelQuery<T> forPage(int page, [int? perPage]) {
    builder.forPage(page, perPage ?? definition.perPage);
    return this;
  }

  /// Locks the selected rows until the transaction ends (`FOR UPDATE`).
  ModelQuery<T> lockForUpdate() {
    builder.lockForUpdate();
    return this;
  }

  /// A shared lock on the selected rows.
  ModelQuery<T> sharedLock() {
    builder.sharedLock();
    return this;
  }

  /// Applies [callback] only when [condition] is true (else [otherwise]):
  /// `query.when(search != null, (q) => q.whereLike('name', '%$search%'))`.
  ModelQuery<T> when(
    bool condition,
    void Function(ModelQuery<T> query) callback, [
    void Function(ModelQuery<T> query)? otherwise,
  ]) {
    if (condition) {
      callback(this);
    } else if (otherwise != null) {
      otherwise(this);
    }
    return this;
  }

  /// Calls [callback] with the query and returns it.
  ModelQuery<T> tap(void Function(ModelQuery<T> query) callback) {
    callback(this);
    return this;
  }

  // ---------------------------------------------------------------------------
  // Scopes, soft deletes
  // ---------------------------------------------------------------------------

  /// Applies the local scope [name] (`scopes:` in the definition).
  ModelQuery<T> scope(String name, [List<Object?> args = const []]) {
    final fn = definition.scopes[name];
    if (fn == null) {
      throw StateError(
        'Model [${definition.table}] has no scope named [$name].',
      );
    }
    fn(this, args);
    return this;
  }

  /// Without every global scope, soft deletes included; with [names], only
  /// those of `namedGlobalScopes`.
  ModelQuery<T> withoutGlobalScopes([List<String>? names]) {
    if (names == null) {
      _withoutGlobalScopes = true;
    } else {
      _withoutNamedScopes.addAll(names);
    }
    return this;
  }

  /// Leaves out the global scope named [name] for this query.
  ModelQuery<T> withoutGlobalScope(String name) => withoutGlobalScopes([name]);

  /// [Model.automaticallyEagerLoad] for the results of this query.
  ModelQuery<T> withRelationshipAutoloading() {
    _autoload = true;
    return this;
  }

  /// Includes soft deleted models.
  ModelQuery<T> withTrashed() {
    _withTrashed = true;
    _onlyTrashed = false;
    return this;
  }

  /// Only soft deleted models.
  ModelQuery<T> onlyTrashed() {
    _onlyTrashed = true;
    _withTrashed = true;
    return this;
  }

  /// Leaves out soft deleted models again after [withTrashed].
  ModelQuery<T> withoutTrashed() {
    _withTrashed = false;
    _onlyTrashed = false;
    return this;
  }

  // ---------------------------------------------------------------------------
  // Relations
  // ---------------------------------------------------------------------------

  /// Eager loads relations: `with(['posts', 'posts.comments'])` or
  /// `with({'posts': (q) => q.where('published', true)})`.
  ModelQuery<T> with_(Object relations) {
    _with.addAll(parseWith(relations));
    return this;
  }

  /// Adds `<relation>_count` columns (`'posts as drafts_count'` names the
  /// column).
  ModelQuery<T> withCount(Object relations) =>
      _withAggregate(relations, 'count', '*');

  /// Adds `<relation>_sum_<column>` columns.
  ModelQuery<T> withSum(Object relations, Object column) => _withAggregate(
    relations,
    'sum',
    QueryBuilder.columnName(column, 'column'),
  );

  /// Adds `<relation>_avg_<column>` columns.
  ModelQuery<T> withAvg(Object relations, Object column) => _withAggregate(
    relations,
    'avg',
    QueryBuilder.columnName(column, 'column'),
  );

  /// Adds `<relation>_min_<column>` columns.
  ModelQuery<T> withMin(Object relations, Object column) => _withAggregate(
    relations,
    'min',
    QueryBuilder.columnName(column, 'column'),
  );

  /// Adds `<relation>_max_<column>` columns.
  ModelQuery<T> withMax(Object relations, Object column) => _withAggregate(
    relations,
    'max',
    QueryBuilder.columnName(column, 'column'),
  );

  /// Adds boolean `<relation>_exists` columns.
  ModelQuery<T> withExists(Object relations) =>
      _withAggregate(relations, 'exists', '*');

  ModelQuery<T> _withAggregate(
    Object relations,
    String function,
    String column,
  ) {
    for (final MapEntry(key: name, :value) in parseWith(relations).entries) {
      // `posts as drafts` (any case of "as"), as Laravel splits it.
      final parts = name.split(RegExp(r'\s+as\s+', caseSensitive: false));
      final relation = parts.first.trim();
      final alias = parts.length > 1
          ? parts[1].trim()
          : _aggregateAlias(relation, function, column);
      _aggregates.add((relation, function, column, alias, value));
    }
    return this;
  }

  /// Laravel's default name: `snake("$relation $function $column")` with
  /// punctuation removed, and no column part for `count` and `exists`.
  static String _aggregateAlias(
    String relation,
    String function,
    String column,
  ) {
    final words = column == '*'
        ? '$relation $function'
        : '$relation $function $column';
    return words
        .replaceAll(RegExp(r'[^A-Za-z0-9\s_]'), '')
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
  }

  /// Filters on the existence of related rows. [relation] may be nested
  /// (`posts.comments`): each level becomes an `EXISTS` inside the previous
  /// one, and [constraint] applies to the last.
  ModelQuery<T> whereHas(
    Object relation, [
    RelationConstraint? constraint,
    String boolean = 'AND',
  ]) => _has(_relationName(relation), constraint, boolean: boolean);

  /// [whereHas] joined with `OR`.
  ModelQuery<T> orWhereHas(Object relation, [RelationConstraint? constraint]) =>
      whereHas(relation, constraint, 'OR');

  /// Models with at least one related row through [relation].
  ModelQuery<T> has(Object relation) => whereHas(relation);

  /// Models with no related row matching [constraint] through [relation].
  ModelQuery<T> whereDoesntHave(
    Object relation, [
    RelationConstraint? constraint,
  ]) => _has(_relationName(relation), constraint, not: true);

  /// [whereDoesntHave] joined with `OR`.
  ModelQuery<T> orWhereDoesntHave(
    Object relation, [
    RelationConstraint? constraint,
  ]) => _has(_relationName(relation), constraint, not: true, boolean: 'OR');

  /// Models with no related row through [relation].
  ModelQuery<T> doesntHave(Object relation) => whereDoesntHave(relation);

  /// [relation] as a name: a string, which a typed relation
  /// (`User.rels.posts`) is at run time; anything else is an [ArgumentError].
  static String _relationName(Object relation) => switch (relation) {
    final String name => name,
    _ => throw ArgumentError.value(
      relation,
      'relation',
      'Not a relation name (a String or a typed relation such as '
          'User.rels.posts)',
    ),
  };

  /// Filters on a `MorphTo` relation whose owner is one of [types] and
  /// matches [constraint] (called with each type).
  ModelQuery<T> whereHasMorph(
    String relation,
    List<ModelDefinition<Model>> types, [
    MorphConstraint? constraint,
  ]) => _hasMorph(_morphTo(relation), types, constraint);

  /// [whereHasMorph] joined with `OR`.
  ModelQuery<T> orWhereHasMorph(
    String relation,
    List<ModelDefinition<Model>> types, [
    MorphConstraint? constraint,
  ]) => _hasMorph(_morphTo(relation), types, constraint, boolean: 'OR');

  /// Rows whose `MorphTo` owner is one of [types] but does not match
  /// [constraint] (or no longer exists).
  ModelQuery<T> whereDoesntHaveMorph(
    String relation,
    List<ModelDefinition<Model>> types, [
    MorphConstraint? constraint,
  ]) => _hasMorph(_morphTo(relation), types, constraint, not: true);

  /// [whereDoesntHaveMorph] joined with `OR`.
  ModelQuery<T> orWhereDoesntHaveMorph(
    String relation,
    List<ModelDefinition<Model>> types, [
    MorphConstraint? constraint,
  ]) => _hasMorph(
    _morphTo(relation),
    types,
    constraint,
    not: true,
    boolean: 'OR',
  );

  ModelQuery<T> _has(
    String name,
    RelationConstraint? constraint, {
    bool not = false,
    String boolean = 'AND',
  }) {
    final dot = name.indexOf('.');
    final head = dot == -1 ? name : name.substring(0, dot);
    // `a.b.c`: the rest is a (positive) whereHas inside the subquery of `a`,
    // as Laravel's hasNested builds it.
    final inner = dot == -1
        ? constraint
        : (ModelQuery<Model> query) {
            query.whereHas(name.substring(dot + 1), constraint);
          };
    final relation = definition.requireRelation(head);
    if (relation is MorphTo) {
      // Laravel queries every stored type ('*'); without reflection the
      // candidates are the types the relation knows.
      final types = relation.knownTypes;
      if (types.isEmpty) {
        throw StateError(
          'MorphTo [$head] on [${definition.table}] lists no types: pass '
          'MorphTo(types: [...]), register Relation.morphMap() or use '
          'whereHasMorph().',
        );
      }
      return _hasMorph(
        relation,
        types,
        inner == null ? null : (query, _) => inner(query),
        not: not,
        boolean: boolean,
        orNull: not,
      );
    }
    final sub = relation.existenceQuery(
      definition as ModelDefinition<Model>,
      _db,
      parentTable: tableName,
    );
    inner?.call(sub);
    builder.whereExists(sub.prepared(), not: not, boolean: boolean);
    return this;
  }

  /// `(type = 'A' AND EXISTS (owner A)) OR (type = 'B' AND EXISTS (...))`,
  /// as Laravel's `hasMorph` builds it; [orNull] also matches rows without
  /// an owner (`doesntHave` on every type).
  ModelQuery<T> _hasMorph(
    MorphTo relation,
    List<ModelDefinition<Model>> types,
    MorphConstraint? constraint, {
    bool not = false,
    String boolean = 'AND',
    bool orNull = false,
  }) {
    if (types.isEmpty) {
      // Laravel compares 0 with the count: never true for "has".
      if (!not) {
        builder.whereRaw('0 = 1', const [], boolean);
      }
      return this;
    }
    final typeColumn = _qualify(relation.morphType);
    builder.where(
      (QueryBuilder group) {
        for (final type in types) {
          final sub = relation.correlatedTo(type, _db, parentTable: tableName);
          constraint?.call(sub, type);
          group.orWhere((QueryBuilder query) {
            query
              ..where(typeColumn, Relation.morphClassOf(type))
              ..whereExists(sub.prepared(), not: not);
          });
        }
        if (orNull) {
          group.orWhereNull(typeColumn);
        }
      },
      null,
      null,
      boolean,
    );
    return this;
  }

  MorphTo _morphTo(String name) {
    final relation = definition.requireRelation(name);
    if (relation is! MorphTo) {
      throw StateError(
        'Relation [$name] on [${definition.table}] is not a MorphTo relation.',
      );
    }
    return relation;
  }

  /// `whereHas` + `with` with the same constraint.
  ModelQuery<T> withWhereHas(
    String relation, [
    RelationConstraint? constraint,
  ]) {
    whereHas(relation, constraint);
    _with[relation] = constraint;
    return this;
  }

  ModelQuery<Model> _correlated(String name, RelationConstraint? constraint) {
    final relation = definition.requireRelation(name);
    final sub = relation.existenceQuery(
      definition as ModelDefinition<Model>,
      _db,
      parentTable: tableName,
    );
    constraint?.call(sub);
    return sub;
  }

  /// The name this query's table goes by: [definition]'s table, or the
  /// alias of a self-relation subquery.
  String get tableName => _tableAlias ?? definition.table;

  /// Gives the table an [alias] (`FROM categories AS laravel_reserved_0`),
  /// used by relation subqueries on the parent's own table. Soft deletes and
  /// key lookups are qualified with it.
  ModelQuery<T> aliasTable(String alias) {
    builder.from(definition.table, alias: alias);
    _tableAlias = alias;
    return this;
  }

  /// Parses `with()` arguments into `name → constraint` pairs.
  ///
  /// `relation:column,column` selects those columns of the relation
  /// (Laravel's `with('user:id,name')`, also as a map key next to a
  /// constraint); the keys the relation matches on are added when left out.
  static Map<String, RelationConstraint?> parseWith(Object relations) {
    final parsed = <String, RelationConstraint?>{};
    void add(String entry, RelationConstraint? constraint) {
      final colon = entry.indexOf(':');
      if (colon < 0) {
        parsed[entry.trim()] = constraint;
        return;
      }
      final columns = [
        for (final column in entry.substring(colon + 1).split(','))
          if (column.trim().isNotEmpty) column.trim(),
      ];
      parsed[entry.substring(0, colon).trim()] = columns.isEmpty
          ? constraint
          : (ModelQuery<Model> query) {
              query.builder.select(columns);
              constraint?.call(query);
            };
    }

    switch (relations) {
      case String():
        add(relations, null);
      case List<Object?>():
        for (final relation in relations) {
          add('$relation', null);
        }
      case Map<Object?, Object?>():
        for (final entry in relations.entries) {
          add('${entry.key}', entry.value as RelationConstraint?);
        }
      default:
        throw ArgumentError.value(
          relations,
          'relations',
          'Expected a String, List or Map',
        );
    }
    return parsed;
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  /// The builder with global scopes, soft deletes and withCount applied.
  QueryBuilder prepared() {
    if (!_withoutGlobalScopes && !_globalScopesApplied) {
      _globalScopesApplied = true;
      for (final scope in definition.globalScopes) {
        scope(this);
      }
      for (final MapEntry(:key, :value)
          in definition.namedGlobalScopes.entries) {
        if (!_withoutNamedScopes.contains(key)) {
          value(this);
        }
      }
    }
    final query = builder.clone();
    if (_with.isNotEmpty) {
      // `select(['title']).with_('user')` still reads `user_id`.
      Relation.keepColumns(query, tableName, [
        for (final name in {for (final w in _with.keys) w.split('.').first})
          ...?definition.relation(name)?.parentColumns,
      ]);
    }
    if (definition.softDeletes && !_withoutGlobalScopes) {
      if (_onlyTrashed) {
        query.whereNotNull(_qualify(definition.deletedAt));
      } else if (!_withTrashed) {
        query.whereNull(_qualify(definition.deletedAt));
      }
    }
    if (_aggregates.isNotEmpty) {
      if (query.ast.columns.isEmpty) {
        query.select(['$tableName.*']);
      }
      final grammar = QueryGrammar.forDialect(
        _db.dialectOf(definition.connection),
      );
      for (final (name, function, column, alias, constraint) in _aggregates) {
        final sub = _correlated(name, constraint);
        if (function != 'exists') {
          final target = column == '*'
              ? '*'
              : grammar.wrap(
                  column.contains('.') ? column : '${sub.tableName}.$column',
                );
          sub.builder.select([
            RawExpression('${function.toUpperCase()}($target)'),
          ]);
        }
        // As an AST, not compiled SQL: PostgreSQL numbers its placeholders
        // ($1, $2...) across the whole statement.
        query.selectSub(sub.prepared(), alias, exists: function == 'exists');
      }
    }
    return query;
  }

  /// The SQL this query runs, with `?` placeholders, for debugging.
  String toSql() => prepared().toSql();

  T _hydrate(Map<String, Object?> row) => definition.hydrate(row, db: _db);

  Future<ModelCollection<T>> _hydrateAll(
    List<Map<String, Object?>> rows,
  ) async {
    // `withExists` columns read as bool, as Laravel casts them.
    final exists = [
      for (final (_, function, _, alias, _) in _aggregates)
        if (function == 'exists') alias,
    ];
    if (exists.isNotEmpty) {
      rows = [
        for (final row in rows)
          {
            ...row,
            for (final alias in exists)
              alias: switch (row[alias]) {
                final bool value => value,
                final num value => value != 0,
                final Object value => '$value' == '1' || '$value' == 't',
                null => false,
              },
          },
      ];
    }
    final autoload = _autoload || Model.automaticallyEagerLoad;
    final models = ModelCollection<T>([for (final row in rows) _hydrate(row)]);
    for (final model in models) {
      await model.fireEvent(ModelEvent.retrieved);
    }
    if (_with.isNotEmpty && models.isNotEmpty) {
      await loadRelationsOn(models, _with, autoload: autoload);
    }
    if (autoload) {
      Model.groupForAutoloading(models);
    }
    return models;
  }

  /// Eager loads [wants] (possibly nested `a.b.c`) onto [models].
  Future<void> loadRelationsOn(
    List<Model> models,
    Map<String, RelationConstraint?> wants, {
    bool autoload = false,
  }) async {
    final byRoot = <String, Map<String, RelationConstraint?>>{};
    final rootConstraints = <String, RelationConstraint?>{};
    for (final entry in wants.entries) {
      final dot = entry.key.indexOf('.');
      if (dot == -1) {
        rootConstraints[entry.key] = entry.value;
        byRoot.putIfAbsent(entry.key, () => {});
      } else {
        final root = entry.key.substring(0, dot);
        byRoot.putIfAbsent(root, () => {})[entry.key.substring(dot + 1)] =
            entry.value;
        rootConstraints.putIfAbsent(root, () => null);
      }
    }
    for (final entry in byRoot.entries) {
      final relation = definition.requireRelation(entry.key);
      final own = rootConstraints[entry.key];
      final nested = {for (final key in entry.value.keys) key.split('.').first};
      await relation.eagerLoad(
        models,
        _db,
        nested.isEmpty
            ? own
            : (ModelQuery<Model> query) {
                own?.call(query);
                // The children's own relations read these columns.
                Relation.keepColumns(query.builder, query.tableName, [
                  for (final name in nested)
                    ...?query.definition.relation(name)?.parentColumns,
                ]);
              },
      );
      if (autoload) {
        Model.groupForAutoloading(relation.loadedModels(models));
      }
      if (entry.value.isNotEmpty) {
        // Grouped by definition: a MorphTo loads posts and videos together,
        // and each needs its own relations.
        final byDefinition = <ModelDefinition<Model>, List<Model>>{};
        for (final child in relation.loadedModels(models)) {
          byDefinition.putIfAbsent(child.modelDefinition, () => []).add(child);
        }
        for (final MapEntry(key: childDefinition, value: children)
            in byDefinition.entries) {
          await childDefinition
              .query(db: _db)
              .loadRelationsOn(children, entry.value, autoload: autoload);
        }
      }
    }
  }

  /// Runs the query and returns the models, with eager loaded relations and
  /// `withCount` values.
  Future<ModelCollection<T>> get() async => _hydrateAll(await prepared().get());

  /// The first model, or null.
  Future<T?> first() async {
    final rows = await prepared().limit(1).get();
    if (rows.isEmpty) {
      return null;
    }
    return (await _hydrateAll(rows)).first;
  }

  /// The first model; throws [ModelNotFoundException] (a 404) without one.
  Future<T> firstOrFail() async =>
      (await first()) ?? (throw ModelNotFoundException(definition.morphClass));

  /// The only matching model; throws [ModelNotFoundException] without one
  /// and `MultipleRecordsFoundException` with more.
  Future<T> sole() async {
    final rows = await prepared().limit(2).get();
    if (rows.isEmpty) {
      throw ModelNotFoundException(definition.morphClass);
    }
    if (rows.length > 1) {
      throw MultipleRecordsFoundException(rows.length);
    }
    return (await _hydrateAll(rows)).first;
  }

  /// The model with primary key [id], or null.
  Future<T?> find(Object id) => whereKey(id).first();

  /// The model with primary key [id]; throws [ModelNotFoundException]
  /// (a 404) without one.
  Future<T> findOrFail(Object id) async =>
      (await find(id)) ??
      (throw ModelNotFoundException(definition.morphClass, [id]));

  /// The models whose primary keys are in [ids].
  Future<ModelCollection<T>> findMany(List<Object?> ids) =>
      whereIn(_qualify(definition.primaryKey), ids).get();

  /// The values of [column]: a list, or a map keyed by [key] when given.
  Future<Object> pluck(Object column, [Object? key]) =>
      prepared().pluck(column, key);

  /// The number of matching models.
  Future<int> count([Object column = '*']) => prepared().count(column);

  /// The sum of [column].
  Future<num?> sum(Object column) => prepared().sum(column);

  /// The average of [column].
  Future<num?> avg(Object column) => prepared().avg(column);

  /// The largest value of [column].
  Future<Object?> max(Object column) => prepared().max(column);

  /// The smallest value of [column].
  Future<Object?> min(Object column) => prepared().min(column);

  /// Whether any model matches.
  Future<bool> exists() => prepared().exists();

  /// Whether no model matches.
  Future<bool> doesntExist() => prepared().doesntExist();

  /// A page of models with the total count, in Laravel's paginator JSON;
  /// [perPage] defaults to the model's `perPage`, [page] to the request's
  /// `?page=`.
  Future<LengthAwarePaginator<T>> paginate({
    int? page,
    int? perPage,
    String? path,
    String pageName = 'page',
    Map<String, String> query = const {},
  }) async {
    final current = page ?? Pagination.resolvePage(pageName);
    final base = path ?? Pagination.resolvePath();
    final size = perPage ?? definition.perPage;
    final rows = await prepared().paginate(
      page: current,
      perPage: size,
      path: base,
      pageName: pageName,
      query: query,
    );
    final models = await _hydrateAll(rows.items);
    return LengthAwarePaginator<T>(
      items: models,
      total: rows.total,
      perPage: size,
      currentPage: rows.currentPage,
      path: base,
      pageName: pageName,
      query: query,
    );
  }

  /// A page of models without counting the total: links to the next and
  /// previous page only.
  Future<SimplePaginator<T>> simplePaginate({
    int? page,
    int? perPage,
    String? path,
    String pageName = 'page',
    Map<String, String> query = const {},
  }) async {
    final current = page ?? Pagination.resolvePage(pageName);
    final base = path ?? Pagination.resolvePath();
    final size = perPage ?? definition.perPage;
    final rows = await prepared().simplePaginate(
      page: current,
      perPage: size,
      path: base,
      pageName: pageName,
      query: query,
    );
    return SimplePaginator<T>(
      items: await _hydrateAll(rows.items),
      perPage: size,
      currentPage: rows.currentPage,
      hasMorePages: rows.hasMorePages,
      path: base,
      pageName: pageName,
      query: query,
    );
  }

  /// A page of models after [cursor] (default: the request's `?cursor=`),
  /// ordered by the query's order columns: fast on large tables, as no rows
  /// are skipped. Laravel's `cursorPaginate` JSON.
  Future<CursorPaginator<T>> cursorPaginate({
    int? perPage,
    Cursor? cursor,
    String? path,
    String cursorName = 'cursor',
    Map<String, String> query = const {},
  }) async {
    final base = path ?? Pagination.resolvePath();
    final from = cursor ?? Pagination.resolveCursor(cursorName);
    final size = perPage ?? definition.perPage;
    final rows = await prepared().cursorPaginate(
      perPage: size,
      cursor: from,
      path: base,
      cursorName: cursorName,
      query: query,
    );
    return CursorPaginator<T>(
      items: await _hydrateAll(rows.items),
      perPage: size,
      nextCursor: rows.nextCursor,
      previousCursor: rows.previousCursor,
      path: base,
      cursorName: cursorName,
      query: query,
    );
  }

  /// Calls [callback] with [size] models at a time and the page number,
  /// until the rows run out; a callback returning `false` stops it.
  Future<void> chunk(
    int size,
    FutureOr<Object?> Function(ModelCollection<T> models, int page) callback,
  ) => prepared().chunk(
    size,
    (rows, page) async => callback(await _hydrateAll(rows), page),
  );

  /// As [chunk], paging by primary key instead of offset, so updating the
  /// rows inside [callback] cannot skip any.
  Future<void> chunkById(
    int size,
    FutureOr<Object?> Function(ModelCollection<T> models) callback,
  ) => prepared().chunkById(
    size,
    (rows) async => callback(await _hydrateAll(rows)),
    column: _qualify(definition.primaryKey),
  );

  /// The models one at a time, read [size] rows per query.
  Stream<T> lazy([int size = 500]) async* {
    await for (final row in prepared().lazy(size)) {
      yield (await _hydrateAll([row])).first;
    }
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Creates and saves a model.
  Future<T> create([Map<String, Object?> attributes = const {}]) async {
    final model = definition.newInstance(attributes, _db);
    await model.save();
    return model;
  }

  /// Creates without saving.
  T make([Map<String, Object?> attributes = const {}]) =>
      definition.newInstance(attributes, _db);

  /// The row matching [attributes], or one created with [values] too;
  /// when another request creates it first, that row (through
  /// [createOrFirst], as Laravel 12).
  Future<T> firstOrCreate(
    Map<String, Object?> attributes, [
    Map<String, Object?> values = const {},
  ]) async =>
      await _copy().where(attributes).first() ??
      await createOrFirst(attributes, values);

  /// Creates the row; when a unique index already holds it (another
  /// request won the race), returns the row matching [attributes]
  /// (Laravel's `createOrFirst`). Inside a transaction the insert runs in a
  /// savepoint, so a refused one leaves the transaction usable (PostgreSQL
  /// aborts it otherwise).
  Future<T> createOrFirst(
    Map<String, Object?> attributes, [
    Map<String, Object?> values = const {},
  ]) async {
    final row = {...attributes, ...values};
    try {
      return _db.inTransactionOn(definition.connection)
          ? await _db.transaction(
              () => create(row),
              connection: definition.connection,
            )
          : await create(row);
    } on UniqueConstraintViolationException {
      final existing = await _copy().where(attributes).first();
      if (existing == null) {
        rethrow;
      }
      return existing;
    }
  }

  /// The first model matching [attributes], or a new unsaved one with
  /// [attributes] and [values].
  Future<T> firstOrNew(
    Map<String, Object?> attributes, [
    Map<String, Object?> values = const {},
  ]) async {
    final existing = await _copy().where(attributes).first();
    return existing ?? make({...attributes, ...values});
  }

  /// The row matching [attributes] updated with [values], or created with
  /// both; safe against a concurrent create (Laravel 12's
  /// `updateOrCreate`).
  Future<T> updateOrCreate(
    Map<String, Object?> attributes,
    Map<String, Object?> values,
  ) async {
    final model = await firstOrCreate(attributes, values);
    if (!model.wasRecentlyCreated) {
      await model.update(values);
    }
    return model;
  }

  /// Bulk update (adds `updated_at`).
  Future<int> update(Map<String, Object?> values) => prepared().update({
    ...values,
    if (definition.timestamps && !values.containsKey(definition.updatedAt))
      definition.updatedAt: _timestamp(),
  });

  /// Bulk delete (soft delete when configured).
  Future<int> delete() {
    if (definition.softDeletes) {
      return prepared().update({
        definition.deletedAt: _timestamp(),
        if (definition.timestamps) definition.updatedAt: _timestamp(),
      });
    }
    return prepared().delete();
  }

  /// Deletes the matching rows for good, soft deleted ones included.
  Future<int> forceDelete() => withTrashed().prepared().delete();

  /// Restores the matching soft deleted models.
  Future<int> restore() => onlyTrashed().prepared().update({
    definition.deletedAt: null,
    if (definition.timestamps) definition.updatedAt: _timestamp(),
  });

  /// Adds [amount] to [column] of the matching rows.
  Future<int> increment(Object column, [num amount = 1]) =>
      prepared().increment(column, amount);

  /// Subtracts [amount] from [column] of the matching rows.
  Future<int> decrement(Object column, [num amount = 1]) =>
      prepared().decrement(column, amount);

  ModelQuery<T> _copy() {
    final copy = ModelQuery<T>(definition, db: _db)
      .._withTrashed = _withTrashed
      .._onlyTrashed = _onlyTrashed
      .._withoutGlobalScopes = _withoutGlobalScopes
      .._autoload = _autoload
      .._withoutNamedScopes.addAll(_withoutNamedScopes);
    final alias = _tableAlias;
    if (alias != null) {
      copy.aliasTable(alias);
    }
    copy.builder.ast.wheres.addAll(builder.ast.wheres);
    return copy;
  }

  String _qualify(String column) =>
      column.contains('.') ? column : '$tableName.$column';

  static String _timestamp() {
    final now = Clock.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}

/// A `with{Count,Sum,Avg,Min,Max,Exists}` column: relation, function,
/// column, alias and constraint.
typedef _Aggregate = (String, String, String, String, RelationConstraint?);
