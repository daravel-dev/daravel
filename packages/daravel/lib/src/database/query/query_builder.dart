import 'dart:convert';

import 'dart:async';

import '../../foundation/clock.dart';
import '../../http/http_exceptions.dart';
import '../../http/json_stream.dart';
import '../database_manager.dart';
import 'paginator.dart';
import 'query_ast.dart';
import 'query_grammar.dart';
import 'sql_tokens.dart';

/// Thrown by `firstOrFail()` / `sole()`.
final class RecordNotFoundException extends HttpException {
  /// A 404 with [message]; `firstOrFail` and `findOrFail` throw it.
  const RecordNotFoundException([
    String message = 'No query results for the given criteria.',
  ]) : super(404, message);
}

/// Thrown by `sole()` when more than one row matches.
final class MultipleRecordsFoundException extends DaravelQueryException {
  /// Thrown by `sole()` when [count] rows match instead of one.
  const MultipleRecordsFoundException(int count)
    : super('$count records were found, expected exactly one.');
}

/// Base for query-layer exceptions.
class DaravelQueryException implements Exception {
  /// A query error with [message].
  const DaravelQueryException(this.message);

  /// What went wrong.
  final String message;
  @override
  String toString() => 'DaravelQueryException: $message';
}

/// Fluent SQL builder (BLUEPRINT_V2 §7.5.3). Mutable like Laravel's; use
/// [clone] to branch. Compiles through the grammar of the connection it runs
/// on, so the same builder works on SQLite, PostgreSQL and MySQL.
final class QueryBuilder {
  /// A query on [table] through the database manager; `DB.table(...)` creates
  /// it, on the given connection or the default one.
  QueryBuilder(this._db, String table, {this._connection, QueryAst? ast})
    : _ast = ast ?? QueryAst(table);

  final DatabaseManager _db;
  final String? _connection;
  final QueryAst _ast;

  /// The underlying AST (read-only use; mutate through the builder).
  QueryAst get ast => _ast;

  /// Independent copy of this builder.
  QueryBuilder clone() =>
      QueryBuilder(_db, _ast.table, connection: _connection, ast: _ast.clone());

  /// Creates a builder for a sub-query on [table] (same connection).
  QueryBuilder newQuery(String table) =>
      QueryBuilder(_db, table, connection: _connection);

  // ---------------------------------------------------------------------------
  // Select
  // ---------------------------------------------------------------------------

  /// Replaces the selected columns: names, `'col as alias'`, or
  /// [RawExpression]s. Without a call the query selects `*`.
  QueryBuilder select(List<Object> columns) {
    _ast.columns
      ..clear()
      ..addAll(columns);
    return this;
  }

  /// Adds [columns] to the selection.
  QueryBuilder addSelect(List<Object> columns) {
    _ast.columns.addAll(columns);
    return this;
  }

  /// Adds a raw select expression with [bindings]:
  /// `selectRaw('price * ? as total', [1.1])`.
  QueryBuilder selectRaw(String sql, [List<Object?> bindings = const []]) =>
      addSelect([RawExpression(sql, bindings)]);

  /// Adds `(subquery) AS alias` to the select list (`selectSub`), or
  /// `EXISTS(subquery) AS alias` when [exists].
  QueryBuilder selectSub(
    QueryBuilder query,
    String alias, {
    bool exists = false,
  }) => addSelect([SubSelect(query._ast, alias, exists: exists)]);

  /// Selects only distinct rows (`SELECT DISTINCT`).
  QueryBuilder distinct([bool value = true]) {
    _ast.distinct = value;
    return this;
  }

  /// Queries [table] instead, as [alias] when given.
  QueryBuilder from(String table, {String? alias}) {
    _ast
      ..table = table
      ..tableAlias = alias
      ..fromSubQuery = null;
    return this;
  }

  /// Queries the result of [sub] as a derived table named [alias]:
  /// `DB.table('x').fromSub(DB.table('orders').select([...]), 'o')`.
  QueryBuilder fromSub(QueryBuilder sub, String alias) {
    _ast
      ..fromSubQuery = sub._ast
      ..tableAlias = alias;
    return this;
  }

  // ---------------------------------------------------------------------------
  // Where
  // ---------------------------------------------------------------------------

  /// `where('col', value)`, `where('col', '>', value)` or
  /// `where((q) => q.where(...).orWhere(...))` for a nested group.
  QueryBuilder where(
    Object column, [
    Object? operatorOrValue,
    Object? value,
    String boolean = 'AND',
  ]) {
    if (column is void Function(QueryBuilder)) {
      final nested = QueryBuilder(_db, _ast.table, connection: _connection);
      column(nested);
      return _add(NestedWhere(nested._ast.wheres, boolean: boolean));
    }
    if (column is Map<String, Object?>) {
      for (final entry in column.entries) {
        where(entry.key, entry.value, null, boolean);
      }
      return this;
    }
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    if (actual == null &&
        (operator == '=' || operator == '!=' || operator == '<>')) {
      return _add(NullWhere('$column', not: operator != '=', boolean: boolean));
    }
    return _add(BasicWhere(column, operator, actual, boolean: boolean));
  }

  /// [where] joined with `OR`.
  QueryBuilder orWhere(
    Object column, [
    Object? operatorOrValue,
    Object? value,
  ]) => where(column, operatorOrValue, value, 'OR');

  /// Negates a nested group: `WHERE NOT (...)`.
  QueryBuilder whereNot(
    void Function(QueryBuilder query) nested, [
    String boolean = 'AND',
  ]) {
    final sub = QueryBuilder(_db, _ast.table, connection: _connection);
    nested(sub);
    return _add(NestedWhere(sub._ast.wheres, not: true, boolean: boolean));
  }

  /// Compares two columns: `whereColumn('updated_at', '>', 'created_at')`.
  QueryBuilder whereColumn(
    String first,
    String operator,
    String second, [
    String boolean = 'AND',
  ]) => _add(
    ColumnWhere(first, SqlTokens.operator(operator), second, boolean: boolean),
  );

  /// `column IN (...)` for a list of [values], or for the rows of a
  /// [QueryBuilder] subquery; [not] makes it `NOT IN`. An empty list matches
  /// nothing, as in Laravel.
  QueryBuilder whereIn(
    String column,
    Object values, {
    bool not = false,
    String boolean = 'AND',
  }) {
    if (values is QueryBuilder) {
      return _add(
        InWhere(
          column,
          const [],
          subQuery: values._ast,
          not: not,
          boolean: boolean,
        ),
      );
    }
    return _add(
      InWhere(
        column,
        List<Object?>.of(values as Iterable<Object?>),
        not: not,
        boolean: boolean,
      ),
    );
  }

  /// `column NOT IN (...)`.
  QueryBuilder whereNotIn(String column, Object values) =>
      whereIn(column, values, not: true);

  /// [whereIn] joined with `OR`.
  QueryBuilder orWhereIn(String column, Object values) =>
      whereIn(column, values, boolean: 'OR');

  /// `column IS NULL`, or `IS NOT NULL` when [not].
  QueryBuilder whereNull(
    String column, {
    bool not = false,
    String boolean = 'AND',
  }) => _add(NullWhere(column, not: not, boolean: boolean));

  /// `column IS NOT NULL`.
  QueryBuilder whereNotNull(String column) => whereNull(column, not: true);

  /// [whereNull] joined with `OR`.
  QueryBuilder orWhereNull(String column) => whereNull(column, boolean: 'OR');

  /// `column BETWEEN from AND to`; [not] makes it `NOT BETWEEN`.
  QueryBuilder whereBetween(
    String column,
    Object? from,
    Object? to, {
    bool not = false,
    String boolean = 'AND',
  }) => _add(BetweenWhere(column, from, to, not: not, boolean: boolean));

  /// `column NOT BETWEEN from AND to`.
  QueryBuilder whereNotBetween(String column, Object? from, Object? to) =>
      whereBetween(column, from, to, not: true);

  /// `EXISTS (subquery)`; [not] makes it `NOT EXISTS`.
  QueryBuilder whereExists(
    QueryBuilder sub, {
    bool not = false,
    String boolean = 'AND',
  }) => _add(ExistsWhere(sub._ast, not: not, boolean: boolean));

  /// `NOT EXISTS (subquery)`.
  QueryBuilder whereNotExists(QueryBuilder sub) => whereExists(sub, not: true);

  /// A raw condition with `?` [bindings]: `whereRaw('price > ?', [100])`.
  /// Never interpolate input into [sql].
  QueryBuilder whereRaw(
    String sql, [
    List<Object?> bindings = const [],
    String boolean = 'AND',
  ]) => _add(RawWhere(sql, bindings, boolean));

  /// [whereRaw] joined with `OR`.
  QueryBuilder orWhereRaw(String sql, [List<Object?> bindings = const []]) =>
      whereRaw(sql, bindings, 'OR');

  /// `column LIKE pattern`, case-insensitive unless [caseSensitive], on every
  /// database (Laravel's `whereLike`).
  QueryBuilder whereLike(
    String column,
    String pattern, {
    bool caseSensitive = false,
    String boolean = 'AND',
  }) {
    if (caseSensitive) {
      return _add(BasicWhere(column, 'LIKE', pattern, boolean: boolean));
    }
    return _add(
      BasicWhere(
        RawExpression('LOWER(${_db.grammarFor(_connection).wrap(column)})'),
        'LIKE',
        pattern.toLowerCase(),
        boolean: boolean,
      ),
    );
  }

  /// Compares the date part of a datetime column: `whereDate('created_at',
  /// '2026-01-31')` or `whereDate('created_at', '>=', '2026-01-01')`.
  QueryBuilder whereDate(
    String column,
    String operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'date', operator, actual));
  }

  /// Compares the year of a date column.
  QueryBuilder whereYear(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'year', operator, actual));
  }

  /// Compares the month (1 to 12) of a date column.
  QueryBuilder whereMonth(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'month', operator, actual));
  }

  /// Compares the day of the month of a date column.
  QueryBuilder whereDay(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'day', operator, actual));
  }

  // Laravel 11's date shortcuts (BuildsWhereDateClauses), against
  // Clock.now(). [columns] is a column or a list of columns.

  /// Rows whose [columns] (a name or a list) are before now (`Clock.now()`).
  QueryBuilder wherePast(Object columns) => _againstNow(columns, '<', 'AND');

  /// Rows whose [columns] are now or earlier.
  QueryBuilder whereNowOrPast(Object columns) =>
      _againstNow(columns, '<=', 'AND');

  /// [wherePast] joined with `OR`.
  QueryBuilder orWherePast(Object columns) => _againstNow(columns, '<', 'OR');

  /// [whereNowOrPast] joined with `OR`.
  QueryBuilder orWhereNowOrPast(Object columns) =>
      _againstNow(columns, '<=', 'OR');

  /// Rows whose [columns] are after now (`Clock.now()`).
  QueryBuilder whereFuture(Object columns) => _againstNow(columns, '>', 'AND');

  /// Rows whose [columns] are now or later.
  QueryBuilder whereNowOrFuture(Object columns) =>
      _againstNow(columns, '>=', 'AND');

  /// [whereFuture] joined with `OR`.
  QueryBuilder orWhereFuture(Object columns) => _againstNow(columns, '>', 'OR');

  /// [whereNowOrFuture] joined with `OR`.
  QueryBuilder orWhereNowOrFuture(Object columns) =>
      _againstNow(columns, '>=', 'OR');

  /// Rows whose [columns] fall on today's date (UTC, `Clock.now()`).
  QueryBuilder whereToday(Object columns) => _againstToday(columns, '=', 'AND');

  /// Rows whose [columns] are before today.
  QueryBuilder whereBeforeToday(Object columns) =>
      _againstToday(columns, '<', 'AND');

  /// Rows whose [columns] are today or earlier.
  QueryBuilder whereTodayOrBefore(Object columns) =>
      _againstToday(columns, '<=', 'AND');

  /// Rows whose [columns] are after today.
  QueryBuilder whereAfterToday(Object columns) =>
      _againstToday(columns, '>', 'AND');

  /// Rows whose [columns] are today or later.
  QueryBuilder whereTodayOrAfter(Object columns) =>
      _againstToday(columns, '>=', 'AND');

  /// [whereToday] joined with `OR`.
  QueryBuilder orWhereToday(Object columns) =>
      _againstToday(columns, '=', 'OR');

  /// [whereBeforeToday] joined with `OR`.
  QueryBuilder orWhereBeforeToday(Object columns) =>
      _againstToday(columns, '<', 'OR');

  /// [whereTodayOrBefore] joined with `OR`.
  QueryBuilder orWhereTodayOrBefore(Object columns) =>
      _againstToday(columns, '<=', 'OR');

  /// [whereAfterToday] joined with `OR`.
  QueryBuilder orWhereAfterToday(Object columns) =>
      _againstToday(columns, '>', 'OR');

  /// [whereTodayOrAfter] joined with `OR`.
  QueryBuilder orWhereTodayOrAfter(Object columns) =>
      _againstToday(columns, '>=', 'OR');

  static Iterable<String> _columnsOf(Object columns) => switch (columns) {
    final String column => [column],
    final Iterable<Object?> list => [for (final c in list) '$c'],
    _ => throw ArgumentError.value(columns, 'columns', 'String or List'),
  };

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `Y-m-d`, in UTC like the timestamps Daravel writes.
  static String _date(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)}';

  QueryBuilder _againstNow(Object columns, String operator, String boolean) {
    final now = Clock.now().toUtc();
    final value =
        '${_date(now)} ${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    for (final column in _columnsOf(columns)) {
      _add(BasicWhere(column, operator, value, boolean: boolean));
    }
    return this;
  }

  QueryBuilder _againstToday(Object columns, String operator, String boolean) {
    final today = _date(Clock.now().toUtc());
    for (final column in _columnsOf(columns)) {
      _add(DatePartWhere(column, 'date', operator, today, boolean: boolean));
    }
    return this;
  }

  /// Rows whose JSON [column] contains [value] (an element of an array, or a
  /// subset of an object); [not] negates it.
  QueryBuilder whereJsonContains(
    String column,
    Object? value, {
    bool not = false,
  }) => _add(JsonWhere(column, 'contains', '=', value, not: not));

  /// Compares the length of the JSON array in [column]:
  /// `whereJsonLength('tags', '>', 2)`.
  QueryBuilder whereJsonLength(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(JsonWhere(column, 'length', operator, actual));
  }

  /// `whereAny(['a','b'], 'like', '%x%')` — any column matches.
  QueryBuilder whereAny(List<String> columns, String operator, Object? value) =>
      where((QueryBuilder q) {
        for (final column in columns) {
          q.orWhere(column, operator, value);
        }
      });

  /// `whereNone(['a','b'], 'like', '%x%')` — no column matches.
  QueryBuilder whereNone(
    List<String> columns,
    String operator,
    Object? value,
  ) => whereNot((QueryBuilder q) {
    for (final column in columns) {
      q.orWhere(column, operator, value);
    }
  });

  /// `whereAll(['a','b'], 'like', '%x%')` — every column matches.
  QueryBuilder whereAll(List<String> columns, String operator, Object? value) =>
      where((QueryBuilder q) {
        for (final column in columns) {
          q.where(column, operator, value);
        }
      });

  // ---------------------------------------------------------------------------
  // Joins
  // ---------------------------------------------------------------------------

  /// An inner join: `join('posts', 'users.id', '=', 'posts.user_id')`, or
  /// with a closure for several conditions: `join('posts', (JoinBuilder j)
  /// => j.on(...).where(...))`. [table] may carry an alias: `'posts as p'`.
  QueryBuilder join(
    String table,
    Object first, [
    String? operator,
    String? second,
    JoinType type = .inner,
  ]) {
    final clause = JoinClause(
      type: type,
      table: _tableName(table),
      alias: _aliasOf(table),
    );
    if (first is void Function(JoinBuilder)) {
      first(JoinBuilder(clause));
    } else {
      clause.conditions.add(
        JoinCondition(
          first: first,
          operator: SqlTokens.operator(operator ?? '='),
          second: second,
        ),
      );
    }
    _ast.joins.add(clause);
    return this;
  }

  /// A left join; arguments as [join].
  QueryBuilder leftJoin(
    String table,
    Object first, [
    String? operator,
    String? second,
  ]) => join(table, first, operator, second, JoinType.left);

  /// A right join; arguments as [join].
  QueryBuilder rightJoin(
    String table,
    Object first, [
    String? operator,
    String? second,
  ]) => join(table, first, operator, second, JoinType.right);

  /// A cross join with [table].
  QueryBuilder crossJoin(String table) {
    _ast.joins.add(
      JoinClause(
        type: .cross,
        table: _tableName(table),
        alias: _aliasOf(table),
      ),
    );
    return this;
  }

  /// Joins the result of [sub] as [alias] on `first operator second`.
  QueryBuilder joinSub(
    QueryBuilder sub,
    String alias,
    String first,
    String operator,
    String second, {
    JoinType type = .inner,
  }) {
    final clause =
        JoinClause(type: type, table: alias, alias: alias, subQuery: sub._ast)
          ..conditions.add(
            JoinCondition(
              first: first,
              operator: SqlTokens.operator(operator),
              second: second,
            ),
          );
    _ast.joins.add(clause);
    return this;
  }

  // ---------------------------------------------------------------------------
  // Grouping, ordering, limits, locks, unions
  // ---------------------------------------------------------------------------

  /// `GROUP BY` [columns].
  QueryBuilder groupBy(List<Object> columns) {
    _ast.groups.addAll(columns);
    return this;
  }

  /// A raw `GROUP BY` expression.
  QueryBuilder groupByRaw(String sql) => groupBy([RawExpression(sql)]);

  /// A `HAVING` condition: `having('total', '>', 100)`.
  QueryBuilder having(
    Object column,
    String operator,
    Object? value, [
    String boolean = 'AND',
  ]) {
    _ast.havings.add(
      HavingClause(
        column,
        SqlTokens.operator(operator),
        value,
        boolean: SqlTokens.boolean(boolean),
      ),
    );
    return this;
  }

  /// [having] joined with `OR`.
  QueryBuilder orHaving(Object column, String operator, Object? value) =>
      having(column, operator, value, 'OR');

  /// A raw `HAVING` condition with `?` [bindings].
  QueryBuilder havingRaw(String sql, [List<Object?> bindings = const []]) {
    _ast.havings.add(
      HavingClause(null, null, null, raw: RawExpression(sql, bindings)),
    );
    return this;
  }

  /// Orders by [column], `asc` or `desc`; any other direction throws.
  QueryBuilder orderBy(Object column, [String direction = 'asc']) {
    final dir = direction.toUpperCase();
    if (dir != 'ASC' && dir != 'DESC') {
      throw ArgumentError.value(
        direction,
        'direction',
        'Order direction must be asc or desc',
      );
    }
    _ast.orders.add(OrderClause(column, dir));
    return this;
  }

  /// Orders by [column], descending.
  QueryBuilder orderByDesc(Object column) => orderBy(column, 'desc');

  /// Newest first, by [column] (`created_at`).
  QueryBuilder latest([String column = 'created_at']) =>
      orderBy(column, 'desc');

  /// Oldest first, by [column] (`created_at`).
  QueryBuilder oldest([String column = 'created_at']) => orderBy(column, 'asc');

  /// A raw `ORDER BY` expression with `?` [bindings].
  QueryBuilder orderByRaw(String sql, [List<Object?> bindings = const []]) {
    _ast.orders.add(OrderClause('', '', raw: RawExpression(sql, bindings)));
    return this;
  }

  /// Cosine distance from a bound vector, as Laravel's grammars write it.
  String _vectorDistance(String column) {
    final grammar = _db.grammarFor(_connection);
    return switch (grammar.dialect) {
      .postgres => '(${grammar.wrap(column)} <=> ?)',
      .mariadb =>
        'vec_distance_cosine(${grammar.wrap(column)}, vec_fromtext(?))',
      _ => throw StateError(
        'Vector distance queries are only supported by PostgreSQL and MariaDB.',
      ),
    };
  }

  /// Selects a vector column so [Cast.vector] can read it. On MariaDB that is
  /// `vec_totext`: the client reads the column's float32 bytes as UTF-8 and
  /// they do not survive it, so a plain `SELECT *` loses a vector there.
  QueryBuilder selectVector(String column) {
    final grammar = _db.grammarFor(_connection);
    if (grammar.dialect != .mariadb) {
      return addSelect([column]);
    }
    final name = grammar.wrap(column);
    return selectRaw('vec_totext($name) AS $name');
  }

  /// Adds the distance from [vector] to the select list, as [alias] or
  /// `{column}_distance`.
  QueryBuilder selectVectorDistance(
    String column,
    List<num> vector, {
    String? alias,
  }) {
    final distance = _vectorDistance(column);
    final name = _db
        .grammarFor(_connection)
        .wrap(alias ?? '${column}_distance');
    return selectRaw('$distance AS $name', [jsonEncode(vector)]);
  }

  /// Keeps rows within [maxDistance] of [vector].
  QueryBuilder whereVectorDistanceLessThan(
    String column,
    List<num> vector,
    double maxDistance, {
    String boolean = 'AND',
  }) => whereRaw('${_vectorDistance(column)} <= ?', [
    jsonEncode(vector),
    maxDistance,
  ], boolean);

  /// Keeps rows at least [minSimilarity] alike, nearest first unless [order]
  /// is false. Cosine distance is 1 minus the similarity.
  QueryBuilder whereVectorSimilarTo(
    String column,
    List<num> vector, {
    double minSimilarity = 0.6,
    bool order = true,
  }) {
    whereVectorDistanceLessThan(column, vector, 1 - minSimilarity);
    return order ? orderByVectorDistance(column, vector) : this;
  }

  /// Nearest to [vector] first.
  QueryBuilder orderByVectorDistance(String column, List<num> vector) =>
      orderByRaw(_vectorDistance(column), [jsonEncode(vector)]);

  /// Random order: `RANDOM()`, or `RAND()` on MySQL.
  QueryBuilder inRandomOrder() => orderByRaw(
    _db.grammarFor(_connection).dialect.isMySqlFamily ? 'RAND()' : 'RANDOM()',
  );

  /// Drops every ordering, then orders by [column] when given.
  QueryBuilder reorder([Object? column, String direction = 'asc']) {
    _ast.orders.clear();
    return column == null ? this : orderBy(column, direction);
  }

  /// At most [value] rows; a negative value removes the limit.
  QueryBuilder limit(int value) {
    _ast.limit = value < 0 ? null : value;
    return this;
  }

  /// Laravel's alias of [limit].
  QueryBuilder take(int value) => limit(value);

  /// Skips the first [value] rows.
  QueryBuilder offset(int value) {
    _ast.offset = value <= 0 ? null : value;
    return this;
  }

  /// Laravel's alias of [offset].
  QueryBuilder skip(int value) => offset(value);

  /// The rows of page [page] (from 1) of [perPage] rows.
  QueryBuilder forPage(int page, [int perPage = 15]) =>
      offset((page - 1) * perPage).limit(perPage);

  /// `FOR UPDATE`: locks the selected rows until the transaction ends.
  /// SQLite ignores it, as its writes lock the database.
  QueryBuilder lockForUpdate() {
    _ast.lock = LockMode.forUpdate;
    return this;
  }

  /// A shared lock (`FOR SHARE`, `LOCK IN SHARE MODE` on MySQL).
  QueryBuilder sharedLock() {
    _ast.lock = LockMode.shared;
    return this;
  }

  /// Appends `UNION` [other]; [all] keeps duplicates.
  QueryBuilder union(QueryBuilder other, {bool all = false}) {
    _ast.unions.add(UnionClause(other._ast, all: all));
    return this;
  }

  /// Appends `UNION ALL` [other].
  QueryBuilder unionAll(QueryBuilder other) => union(other, all: true);

  /// Applies [callback] only when [condition] is true (else [otherwise]).
  QueryBuilder when(
    bool condition,
    void Function(QueryBuilder query) callback, [
    void Function(QueryBuilder query)? otherwise,
  ]) {
    if (condition) {
      callback(this);
    } else if (otherwise != null) {
      otherwise(this);
    }
    return this;
  }

  /// Applies [callback] only when [condition] is false (else [otherwise]).
  QueryBuilder unless(
    bool condition,
    void Function(QueryBuilder query) callback,
  ) => when(!condition, callback);

  /// Calls [callback] with the query and returns it, to reuse a set of
  /// conditions.
  QueryBuilder tap(void Function(QueryBuilder query) callback) {
    callback(this);
    return this;
  }

  // ---------------------------------------------------------------------------
  // Compilation
  // ---------------------------------------------------------------------------

  /// Compiled SQL for the connection's dialect (debugging / tests).
  String toSql() => _db.grammarFor(_connection).compileSelect(_ast).sql;

  /// Bindings in order (debugging / tests).
  List<Object?> getBindings() =>
      _db.grammarFor(_connection).compileSelect(_ast).bindings;

  /// SQL with bindings inlined (debugging only — never execute this).
  String toRawSql() {
    final compiled = _db.grammarFor(_connection).compileSelect(_ast);
    var index = 0;
    return compiled.sql.replaceAllMapped(RegExp(r'\?|\$\d+'), (_) {
      final value = compiled.bindings[index++];
      return switch (value) {
        null => 'NULL',
        num() => '$value',
        bool() => value ? '1' : '0',
        _ => "'${'$value'.replaceAll("'", "''")}'",
      };
    });
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Runs the query and returns its rows as maps of column to value.
  Future<List<Map<String, Object?>>> get() async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileSelect(_ast);
    return executor.select(compiled.sql, compiled.bindings);
  }

  /// The first row, or null.
  Future<Map<String, Object?>?> first() async {
    final rows = await clone().limit(1).get();
    return rows.isEmpty ? null : rows.first;
  }

  /// The first row; throws [RecordNotFoundException] (a 404) without one.
  Future<Map<String, Object?>> firstOrFail() async {
    final row = await first();
    if (row == null) {
      throw const RecordNotFoundException();
    }
    return row;
  }

  /// Exactly one row, else [RecordNotFoundException] / [MultipleRecordsFoundException].
  Future<Map<String, Object?>> sole() async {
    final rows = await clone().limit(2).get();
    if (rows.isEmpty) {
      throw const RecordNotFoundException();
    }
    if (rows.length > 1) {
      throw MultipleRecordsFoundException(rows.length);
    }
    return rows.first;
  }

  /// The row whose [column] (`id`) is [id], or null.
  Future<Map<String, Object?>?> find(Object? id, {String column = 'id'}) =>
      clone().where(column, id).first();

  /// The value of [column] in the first row, or null.
  Future<T?> value<T>(String column) async {
    final row = await clone().select([column]).first();
    return row?.values.first as T?;
  }

  /// Values of [column]; keyed by [key] when given.
  Future<Object> pluck(String column, [String? key]) async {
    final rows = await clone().select([column, ?key]).get();
    final columnName = column.split(' as ').last.split('.').last;
    if (key == null) {
      return [for (final row in rows) row[columnName]];
    }
    final keyName = key.split(' as ').last.split('.').last;
    return {for (final row in rows) row[keyName]: row[columnName]};
  }

  /// Whether any row matches.
  Future<bool> exists() async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileExists(_ast);
    final rows = await executor.select(compiled.sql, compiled.bindings);
    final value = rows.first.values.first;
    return value == true || value == 1 || value == 't';
  }

  /// Whether no row matches.
  Future<bool> doesntExist() async => !(await exists());

  /// The number of matching rows, or of non-null values of [column].
  Future<int> count([Object column = '*']) async =>
      ((await _aggregate('count', column)) as num? ?? 0).toInt();

  /// The sum of [column], or null without rows.
  Future<num?> sum(Object column) async =>
      (await _aggregate('sum', column)) as num?;

  /// The average of [column], or null without rows.
  Future<num?> avg(Object column) async =>
      (await _aggregate('avg', column)) as num?;

  /// The smallest value of [column], or null without rows.
  Future<Object?> min(Object column) => _aggregate('min', column);

  /// The largest value of [column], or null without rows.
  Future<Object?> max(Object column) => _aggregate('max', column);

  Future<Object?> _aggregate(String function, Object column) async {
    final query = _ast.clone()
      ..aggregate = AggregateClause(function, column)
      ..orders.clear()
      ..limit = null
      ..offset = null;
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileSelect(query);
    final rows = await executor.select(compiled.sql, compiled.bindings);
    return rows.isEmpty ? null : rows.first['aggregate'];
  }

  /// A page of [perPage] rows with the total count, in Laravel's paginator
  /// JSON. [page] defaults to the request's `?page=` ([pageName]), [path] to
  /// the request path; [query] is kept in the page links.
  Future<LengthAwarePaginator<Map<String, Object?>>> paginate({
    int? page,
    int perPage = 15,
    String? path,
    String pageName = 'page',
    Map<String, String> query = const {},
  }) async {
    final current = page ?? Pagination.resolvePage(pageName);
    final base = path ?? Pagination.resolvePath();
    final total = await count();
    final items = total == 0
        ? <Map<String, Object?>>[]
        : await clone().forPage(current, perPage).get();
    return LengthAwarePaginator(
      items: items,
      total: total,
      perPage: perPage,
      currentPage: current,
      path: base,
      pageName: pageName,
      query: query,
    );
  }

  /// A page of [perPage] rows without counting the total: one query, links
  /// to the next and previous page only. Arguments as [paginate].
  Future<SimplePaginator<Map<String, Object?>>> simplePaginate({
    int? page,
    int perPage = 15,
    String? path,
    String pageName = 'page',
    Map<String, String> query = const {},
  }) async {
    final current = page ?? Pagination.resolvePage(pageName);
    final base = path ?? Pagination.resolvePath();
    final rows = await clone()
        .offset((current - 1) * perPage)
        .limit(perPage + 1)
        .get();
    final hasMore = rows.length > perPage;
    return SimplePaginator(
      items: hasMore ? rows.sublist(0, perPage) : rows,
      perPage: perPage,
      currentPage: current,
      hasMorePages: hasMore,
      path: base,
      pageName: pageName,
      query: query,
    );
  }

  /// Keyset pagination over the builder's `orderBy` columns (required, and
  /// they must identify rows uniquely, e.g. `orderBy('id')`).
  Future<CursorPaginator<Map<String, Object?>>> cursorPaginate({
    int perPage = 15,
    Cursor? cursor,
    String? path,
    String cursorName = 'cursor',
    Map<String, String> query = const {},
  }) async {
    final base = path ?? Pagination.resolvePath();
    final from = cursor ?? Pagination.resolveCursor(cursorName);
    if (_ast.orders.isEmpty || _ast.orders.any((o) => o.raw != null)) {
      throw StateError(
        'cursorPaginate() requires orderBy() on unique columns.',
      );
    }
    final columns = [for (final o in _ast.orders) '${o.column}'];
    final forward = from?.pointsToNext ?? true;
    final q = clone();
    if (from != null) {
      q.where(
        (QueryBuilder nested) => _applyCursor(nested, columns, from, forward),
      );
      if (!forward) {
        q._ast.orders
          ..clear()
          ..addAll([
            for (final o in _ast.orders)
              OrderClause(o.column, o.direction == 'ASC' ? 'DESC' : 'ASC'),
          ]);
      }
    }
    var rows = await q.limit(perPage + 1).get();
    final hasMore = rows.length > perPage;
    if (hasMore) {
      rows = rows.sublist(0, perPage);
    }
    if (!forward) {
      rows = rows.reversed.toList();
    }
    Cursor? make(Map<String, Object?> row, bool next) => Cursor({
      for (final c in columns) c: row[c.split('.').last],
    }, pointsToNext: next);
    final next = rows.isEmpty
        ? null
        : (forward
              ? (hasMore ? make(rows.last, true) : null)
              : make(rows.last, true));
    final prev = rows.isEmpty
        ? null
        : (forward
              ? (from == null ? null : make(rows.first, false))
              : (hasMore ? make(rows.first, false) : null));
    return CursorPaginator(
      items: rows,
      perPage: perPage,
      nextCursor: next,
      previousCursor: prev,
      path: base,
      cursorName: cursorName,
      query: query,
    );
  }

  void _applyCursor(
    QueryBuilder nested,
    List<String> columns,
    Cursor cursor,
    bool forward,
  ) {
    // Row-value comparison expanded: (a > ?) OR (a = ? AND b > ?) ...
    for (var i = 0; i < columns.length; i++) {
      nested.orWhere((QueryBuilder group) {
        for (var j = 0; j < i; j++) {
          group.where(columns[j], cursor.values[columns[j]]);
        }
        final desc = _ast.orders[i].direction == 'DESC';
        final op = (desc != forward) ? '>' : '<';
        group.where(columns[i], op, cursor.values[columns[i]]);
      });
    }
  }

  /// Processes rows in chunks of [size]; stop early by returning `false`.
  Future<void> chunk(
    int size,
    FutureOr<Object?> Function(List<Map<String, Object?>> rows, int page)
    callback,
  ) async {
    var page = 1;
    while (true) {
      final rows = await clone().forPage(page, size).get();
      if (rows.isEmpty) {
        return;
      }
      if (await callback(rows, page) == false || rows.length < size) {
        return;
      }
      page++;
    }
  }

  /// Chunks by ascending [column] (stable while rows are inserted/deleted).
  Future<void> chunkById(
    int size,
    FutureOr<Object?> Function(List<Map<String, Object?>> rows) callback, {
    String column = 'id',
  }) async {
    Object? last;
    while (true) {
      final q = clone().reorder(column).limit(size);
      if (last != null) {
        q.where(column, '>', last);
      }
      final rows = await q.get();
      if (rows.isEmpty) {
        return;
      }
      if (await callback(rows) == false || rows.length < size) {
        return;
      }
      last = rows.last[column.split('.').last];
    }
  }

  /// Streams rows lazily in chunks of [size].
  Stream<Map<String, Object?>> lazy([int size = 500]) async* {
    var page = 1;
    while (true) {
      final rows = await clone().forPage(page, size).get();
      for (final row in rows) {
        yield row;
      }
      if (rows.length < size) {
        return;
      }
      page++;
    }
  }

  /// The rows as the bytes of a JSON array, written [chunk] rows at a time
  /// ([lazy]) for `Response.stream(..., contentType: 'application/json')`:
  /// a large result set reaches the client without being held whole in the
  /// isolate, and no model is built on the way. [phpCompatible] writes
  /// PHP's `json_encode()` bytes. Order the query (`orderBy('id')`): the
  /// chunks are separate page queries, as with [lazy].
  Stream<List<int>> streamJson({int chunk = 500, bool phpCompatible = false}) =>
      jsonArrayBytes(lazy(chunk), phpCompatible: phpCompatible);

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Inserts one row (a map) or many (a list of maps) and returns the
  /// number of rows inserted.
  Future<int> insert(Object rows) async {
    final list = _rows(rows);
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileInsert(_ast.table, list);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  /// Inserts [rows], skipping those that break a unique constraint
  /// (`INSERT OR IGNORE`, `ON CONFLICT DO NOTHING`, `INSERT IGNORE`).
  Future<int> insertOrIgnore(Object rows) async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileInsert(_ast.table, _rows(rows), ignore: true);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  /// Inserts [row] and returns its auto-incremented [idColumn].
  Future<Object?> insertGetId(
    Map<String, Object?> row, {
    String idColumn = 'id',
  }) async {
    final executor = await _db.executor(_connection);
    final grammar = QueryGrammar.forDialect(executor.dialect);
    final compiled = grammar.compileInsertGetId(_ast.table, row, idColumn);
    if (grammar.supportsReturning && executor.dialect == .postgres) {
      final rows = await executor.select(compiled.sql, compiled.bindings);
      return rows.first[idColumn];
    }
    return executor.insertGetId(compiled.sql, compiled.bindings);
  }

  /// Insert or update on conflict of [uniqueBy]; [update] defaults to every
  /// non-unique column.
  Future<int> upsert(
    Object rows,
    List<String> uniqueBy, [
    List<String>? update,
  ]) async {
    final list = _rows(rows);
    final columns =
        update ?? list.first.keys.where((k) => !uniqueBy.contains(k)).toList();
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileUpsert(_ast.table, list, uniqueBy, columns);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  /// Updates the matching rows with [values] and returns how many changed.
  Future<int> update(Map<String, Object?> values) async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileUpdate(_ast, values);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  /// Updates the row matching [attributes] with [values], or inserts both
  /// when none matches.
  Future<bool> updateOrInsert(
    Map<String, Object?> attributes, [
    Map<String, Object?> values = const {},
  ]) async {
    final q = clone().where(attributes);
    if (await q.exists()) {
      if (values.isNotEmpty) {
        await q.update(values);
      }
      return true;
    }
    await insert({...attributes, ...values});
    return true;
  }

  /// Adds [amount] to [column] of the matching rows in one statement, and
  /// sets [extra] columns too.
  Future<int> increment(
    String column, [
    num amount = 1,
    Map<String, Object?> extra = const {},
  ]) {
    final wrapped = _db.grammarFor(_connection).wrap(column);
    return update({
      column: RawExpression('$wrapped + ?', [amount]),
      ...extra,
    });
  }

  /// Subtracts [amount] from [column] of the matching rows, and sets
  /// [extra] columns too.
  Future<int> decrement(
    String column, [
    num amount = 1,
    Map<String, Object?> extra = const {},
  ]) {
    final wrapped = _db.grammarFor(_connection).wrap(column);
    return update({
      column: RawExpression('$wrapped - ?', [amount]),
      ...extra,
    });
  }

  /// Deletes the matching rows, or the row with `id` [id], and returns how
  /// many were deleted.
  Future<int> delete([Object? id]) async {
    final q = id == null ? this : clone().where('id', id);
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileDelete(q._ast);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  /// Empties the table (`DELETE FROM` on SQLite, `TRUNCATE` elsewhere).
  Future<void> truncate() async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileTruncate(_ast.table);
    await executor.execute(compiled.sql, compiled.bindings);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Every where clause comes through here: its `boolean` must be `AND` or
  /// `OR` ([SqlTokens.boolean]), whichever method made it.
  QueryBuilder _add(WhereClause clause) {
    SqlTokens.boolean(clause.boolean);
    _ast.wheres.add(clause);
    return this;
  }

  static (String, Object?) _operatorAndValue(
    Object? operatorOrValue,
    Object? value,
  ) {
    if (value == null &&
        operatorOrValue is String &&
        SqlTokens.isOperator(operatorOrValue)) {
      // where('col', '>') without a value is ambiguous; treat as value.
      return ('=', operatorOrValue);
    }
    if (value != null ||
        (operatorOrValue is String && SqlTokens.isOperator(operatorOrValue))) {
      return (SqlTokens.operator('$operatorOrValue'), value);
    }
    return ('=', operatorOrValue);
  }

  static List<Map<String, Object?>> _rows(Object rows) => switch (rows) {
    Map<String, Object?>() => [rows],
    List<Object?>() => [for (final row in rows) row! as Map<String, Object?>],
    _ => throw ArgumentError.value(
      rows,
      'rows',
      'Expected a Map or a List<Map>',
    ),
  };

  static String _tableName(String table) {
    final match = RegExp(
      r'^(\S+)\s+(?:as\s+)?(\S+)$',
      caseSensitive: false,
    ).firstMatch(table.trim());
    return match == null ? table.trim() : match.group(1)!;
  }

  static String? _aliasOf(String table) {
    final match = RegExp(
      r'^(\S+)\s+(?:as\s+)?(\S+)$',
      caseSensitive: false,
    ).firstMatch(table.trim());
    return match?.group(2);
  }
}

/// Fluent `ON` builder for closure joins.
final class JoinBuilder {
  /// Wraps a join clause; [QueryBuilder.join] passes it to the closure.
  JoinBuilder(this._clause);
  final JoinClause _clause;

  /// An `ON first operator second` condition comparing two columns.
  JoinBuilder on(
    Object first,
    String operator,
    String second, [
    String boolean = 'AND',
  ]) {
    _clause.conditions.add(
      JoinCondition(
        first: first,
        operator: SqlTokens.operator(operator),
        second: second,
        boolean: SqlTokens.boolean(boolean),
      ),
    );
    return this;
  }

  /// An `ON` condition joined with `OR`.
  JoinBuilder orOn(Object first, String operator, String second) =>
      on(first, operator, second, 'OR');

  /// A join condition comparing [column] with a bound [value].
  JoinBuilder where(
    Object column,
    String operator,
    Object? value, [
    String boolean = 'AND',
  ]) {
    _clause.conditions.add(
      JoinCondition(
        first: column,
        operator: SqlTokens.operator(operator),
        second: value,
        boolean: SqlTokens.boolean(boolean),
        isValue: true,
      ),
    );
    return this;
  }
}
