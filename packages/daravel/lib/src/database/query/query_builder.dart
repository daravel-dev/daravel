import 'dart:async';

import '../../http/http_exceptions.dart';
import '../database_manager.dart';
import 'paginator.dart';
import 'query_ast.dart';
import 'query_grammar.dart';

/// Thrown by `firstOrFail()` / `sole()`.
final class RecordNotFoundException extends HttpException {
  const RecordNotFoundException([
    String message = 'No query results for the given criteria.',
  ]) : super(404, message);
}

/// Thrown by `sole()` when more than one row matches.
final class MultipleRecordsFoundException extends DaravelQueryException {
  const MultipleRecordsFoundException(int count)
    : super('$count records were found, expected exactly one.');
}

/// Base for query-layer exceptions.
class DaravelQueryException implements Exception {
  const DaravelQueryException(this.message);
  final String message;
  @override
  String toString() => 'DaravelQueryException: $message';
}

/// Fluent SQL builder (BLUEPRINT_V2 §7.5.3). Mutable like Laravel's; use
/// [clone] to branch. Compiles through the grammar of the connection it runs
/// on, so the same builder works on SQLite, PostgreSQL and MySQL.
final class QueryBuilder {
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

  QueryBuilder select(List<Object> columns) {
    _ast.columns
      ..clear()
      ..addAll(columns);
    return this;
  }

  QueryBuilder addSelect(List<Object> columns) {
    _ast.columns.addAll(columns);
    return this;
  }

  QueryBuilder selectRaw(String sql, [List<Object?> bindings = const []]) =>
      addSelect([RawExpression(sql, bindings)]);

  /// Adds `(subquery) AS alias` to the select list (`selectSub`), or
  /// `EXISTS(subquery) AS alias` when [exists].
  QueryBuilder selectSub(
    QueryBuilder query,
    String alias, {
    bool exists = false,
  }) => addSelect([SubSelect(query._ast, alias, exists: exists)]);

  QueryBuilder distinct([bool value = true]) {
    _ast.distinct = value;
    return this;
  }

  QueryBuilder from(String table, {String? alias}) {
    _ast
      ..table = table
      ..tableAlias = alias
      ..fromSubQuery = null;
    return this;
  }

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
      _ast.wheres.add(NestedWhere(nested._ast.wheres, boolean: boolean));
      return this;
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

  QueryBuilder orWhere(
    Object column, [
    Object? operatorOrValue,
    Object? value,
  ]) => where(column, operatorOrValue, value, 'OR');

  QueryBuilder whereNot(
    void Function(QueryBuilder query) nested, [
    String boolean = 'AND',
  ]) {
    final sub = QueryBuilder(_db, _ast.table, connection: _connection);
    nested(sub);
    return _add(NestedWhere(sub._ast.wheres, not: true, boolean: boolean));
  }

  QueryBuilder whereColumn(
    String first,
    String operator,
    String second, [
    String boolean = 'AND',
  ]) => _add(ColumnWhere(first, operator, second, boolean: boolean));

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

  QueryBuilder whereNotIn(String column, Object values) =>
      whereIn(column, values, not: true);
  QueryBuilder orWhereIn(String column, Object values) =>
      whereIn(column, values, boolean: 'OR');

  QueryBuilder whereNull(
    String column, {
    bool not = false,
    String boolean = 'AND',
  }) => _add(NullWhere(column, not: not, boolean: boolean));

  QueryBuilder whereNotNull(String column) => whereNull(column, not: true);
  QueryBuilder orWhereNull(String column) => whereNull(column, boolean: 'OR');

  QueryBuilder whereBetween(
    String column,
    Object? from,
    Object? to, {
    bool not = false,
    String boolean = 'AND',
  }) => _add(BetweenWhere(column, from, to, not: not, boolean: boolean));

  QueryBuilder whereNotBetween(String column, Object? from, Object? to) =>
      whereBetween(column, from, to, not: true);

  QueryBuilder whereExists(
    QueryBuilder sub, {
    bool not = false,
    String boolean = 'AND',
  }) => _add(ExistsWhere(sub._ast, not: not, boolean: boolean));

  QueryBuilder whereNotExists(QueryBuilder sub) => whereExists(sub, not: true);

  QueryBuilder whereRaw(
    String sql, [
    List<Object?> bindings = const [],
    String boolean = 'AND',
  ]) => _add(RawWhere(sql, bindings, boolean));

  QueryBuilder orWhereRaw(String sql, [List<Object?> bindings = const []]) =>
      whereRaw(sql, bindings, 'OR');

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

  QueryBuilder whereDate(
    String column,
    String operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'date', operator, actual));
  }

  QueryBuilder whereYear(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'year', operator, actual));
  }

  QueryBuilder whereMonth(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'month', operator, actual));
  }

  QueryBuilder whereDay(
    String column,
    Object operatorOrValue, [
    Object? value,
  ]) {
    final (operator, actual) = _operatorAndValue(operatorOrValue, value);
    return _add(DatePartWhere(column, 'day', operator, actual));
  }

  QueryBuilder whereJsonContains(
    String column,
    Object? value, {
    bool not = false,
  }) => _add(JsonWhere(column, 'contains', '=', value, not: not));

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
        JoinCondition(first: first, operator: operator ?? '=', second: second),
      );
    }
    _ast.joins.add(clause);
    return this;
  }

  QueryBuilder leftJoin(
    String table,
    Object first, [
    String? operator,
    String? second,
  ]) => join(table, first, operator, second, JoinType.left);

  QueryBuilder rightJoin(
    String table,
    Object first, [
    String? operator,
    String? second,
  ]) => join(table, first, operator, second, JoinType.right);

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
            JoinCondition(first: first, operator: operator, second: second),
          );
    _ast.joins.add(clause);
    return this;
  }

  // ---------------------------------------------------------------------------
  // Grouping, ordering, limits, locks, unions
  // ---------------------------------------------------------------------------

  QueryBuilder groupBy(List<Object> columns) {
    _ast.groups.addAll(columns);
    return this;
  }

  QueryBuilder groupByRaw(String sql) => groupBy([RawExpression(sql)]);

  QueryBuilder having(
    Object column,
    String operator,
    Object? value, [
    String boolean = 'AND',
  ]) {
    _ast.havings.add(HavingClause(column, operator, value, boolean: boolean));
    return this;
  }

  QueryBuilder orHaving(Object column, String operator, Object? value) =>
      having(column, operator, value, 'OR');

  QueryBuilder havingRaw(String sql, [List<Object?> bindings = const []]) {
    _ast.havings.add(
      HavingClause(null, null, null, raw: RawExpression(sql, bindings)),
    );
    return this;
  }

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

  QueryBuilder orderByDesc(Object column) => orderBy(column, 'desc');
  QueryBuilder latest([String column = 'created_at']) =>
      orderBy(column, 'desc');
  QueryBuilder oldest([String column = 'created_at']) => orderBy(column, 'asc');

  QueryBuilder orderByRaw(String sql, [List<Object?> bindings = const []]) {
    _ast.orders.add(OrderClause('', '', raw: RawExpression(sql, bindings)));
    return this;
  }

  QueryBuilder inRandomOrder() => orderByRaw(
    _db.grammarFor(_connection).dialect == .mysql ? 'RAND()' : 'RANDOM()',
  );

  QueryBuilder reorder([Object? column, String direction = 'asc']) {
    _ast.orders.clear();
    return column == null ? this : orderBy(column, direction);
  }

  QueryBuilder limit(int value) {
    _ast.limit = value < 0 ? null : value;
    return this;
  }

  QueryBuilder take(int value) => limit(value);

  QueryBuilder offset(int value) {
    _ast.offset = value <= 0 ? null : value;
    return this;
  }

  QueryBuilder skip(int value) => offset(value);

  QueryBuilder forPage(int page, [int perPage = 15]) =>
      offset((page - 1) * perPage).limit(perPage);

  QueryBuilder lockForUpdate() {
    _ast.lock = LockMode.forUpdate;
    return this;
  }

  QueryBuilder sharedLock() {
    _ast.lock = LockMode.shared;
    return this;
  }

  QueryBuilder union(QueryBuilder other, {bool all = false}) {
    _ast.unions.add(UnionClause(other._ast, all: all));
    return this;
  }

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

  QueryBuilder unless(
    bool condition,
    void Function(QueryBuilder query) callback,
  ) => when(!condition, callback);

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

  Future<List<Map<String, Object?>>> get() async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileSelect(_ast);
    return executor.select(compiled.sql, compiled.bindings);
  }

  Future<Map<String, Object?>?> first() async {
    final rows = await clone().limit(1).get();
    return rows.isEmpty ? null : rows.first;
  }

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

  Future<Map<String, Object?>?> find(Object? id, {String column = 'id'}) =>
      clone().where(column, id).first();

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

  Future<bool> exists() async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileExists(_ast);
    final rows = await executor.select(compiled.sql, compiled.bindings);
    final value = rows.first.values.first;
    return value == true || value == 1 || value == 't';
  }

  Future<bool> doesntExist() async => !(await exists());

  Future<int> count([Object column = '*']) async =>
      ((await _aggregate('count', column)) as num? ?? 0).toInt();
  Future<num?> sum(Object column) async =>
      (await _aggregate('sum', column)) as num?;
  Future<num?> avg(Object column) async =>
      (await _aggregate('avg', column)) as num?;
  Future<Object?> min(Object column) => _aggregate('min', column);
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

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<int> insert(Object rows) async {
    final list = _rows(rows);
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileInsert(_ast.table, list);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  Future<int> insertOrIgnore(Object rows) async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileInsert(_ast.table, _rows(rows), ignore: true);
    return executor.execute(compiled.sql, compiled.bindings);
  }

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

  Future<int> update(Map<String, Object?> values) async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileUpdate(_ast, values);
    return executor.execute(compiled.sql, compiled.bindings);
  }

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

  Future<int> delete([Object? id]) async {
    final q = id == null ? this : clone().where('id', id);
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileDelete(q._ast);
    return executor.execute(compiled.sql, compiled.bindings);
  }

  Future<void> truncate() async {
    final executor = await _db.executor(_connection);
    final compiled = QueryGrammar.forDialect(executor.dialect)
        .compileTruncate(_ast.table);
    await executor.execute(compiled.sql, compiled.bindings);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  QueryBuilder _add(WhereClause clause) {
    _ast.wheres.add(clause);
    return this;
  }

  static (String, Object?) _operatorAndValue(
    Object? operatorOrValue,
    Object? value,
  ) {
    if (value == null &&
        operatorOrValue is String &&
        _operators.contains(operatorOrValue.toUpperCase())) {
      // where('col', '>') without a value is ambiguous; treat as value.
      return ('=', operatorOrValue);
    }
    if (value != null ||
        (operatorOrValue is String &&
            _operators.contains(operatorOrValue.toUpperCase()))) {
      final operator = '$operatorOrValue'.toUpperCase();
      if (!_operators.contains(operator)) {
        throw ArgumentError.value(
          operatorOrValue,
          'operator',
          'Unsupported SQL operator',
        );
      }
      return (operator == '!=' ? '<>' : operator, value);
    }
    return ('=', operatorOrValue);
  }

  static const Set<String> _operators = {
    '=',
    '<',
    '>',
    '<=',
    '>=',
    '<>',
    '!=',
    'LIKE',
    'NOT LIKE',
    'ILIKE',
    'IN',
    'IS',
    'IS NOT',
    '&',
    '|',
    '<<',
    '>>',
    '~',
    '!~',
    'REGEXP',
  };

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
  JoinBuilder(this._clause);
  final JoinClause _clause;

  JoinBuilder on(
    Object first,
    String operator,
    String second, [
    String boolean = 'AND',
  ]) {
    _clause.conditions.add(
      JoinCondition(
        first: first,
        operator: operator,
        second: second,
        boolean: boolean,
      ),
    );
    return this;
  }

  JoinBuilder orOn(Object first, String operator, String second) =>
      on(first, operator, second, 'OR');

  JoinBuilder where(
    Object column,
    String operator,
    Object? value, [
    String boolean = 'AND',
  ]) {
    _clause.conditions.add(
      JoinCondition(
        first: column,
        operator: operator,
        second: value,
        boolean: boolean,
        isValue: true,
      ),
    );
    return this;
  }
}
