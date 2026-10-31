import '../query_executor.dart';
import 'query_ast.dart';

/// SQL text plus its ordered bindings, ready for a driver.
final class CompiledQuery {
  const CompiledQuery(this.sql, this.bindings);

  final String sql;
  final List<Object?> bindings;

  @override
  String toString() => '$sql  $bindings';
}

/// Accumulates bindings while compiling and emits dialect placeholders.
final class Compilation {
  Compilation(this.grammar);

  final QueryGrammar grammar;
  final List<Object?> bindings = <Object?>[];

  /// Registers [value] and returns its placeholder (`?` or `$n`).
  String bind(Object? value) {
    bindings.add(value);
    return grammar.parameter(bindings.length);
  }

  /// Inlines a raw expression, appending its bindings in order.
  String raw(RawExpression expression) {
    if (expression.bindings.isEmpty) {
      return expression.sql;
    }
    // Raw fragments use `?`; renumber for dialects with indexed placeholders.
    final buffer = StringBuffer();
    var index = 0;
    for (var i = 0; i < expression.sql.length; i++) {
      final char = expression.sql[i];
      if (char == '?' && index < expression.bindings.length) {
        buffer.write(bind(expression.bindings[index++]));
      } else {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }
}

/// Compiles a [QueryAst] into SQL for one dialect (ADR-005). Placeholders
/// are emitted while compiling, never rewritten textually afterwards.
abstract class QueryGrammar {
  const QueryGrammar();

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final RegExp _alias = RegExp(
    r'^(.+?)\s+as\s+(.+)$',
    caseSensitive: false,
  );

  SqlDialect get dialect;

  /// Placeholder for the [index]-th (1-based) binding.
  String parameter(int index);

  /// Opening/closing identifier quotes.
  String get quoteOpen => '"';
  String get quoteClose => '"';

  bool get supportsReturning => true;
  bool get supportsSavepoints => true;

  /// Picks the grammar for [dialect].
  static QueryGrammar forDialect(SqlDialect dialect) => switch (dialect) {
    .sqlite => const SqliteQueryGrammar(),
    .postgres => const PostgresQueryGrammar(),
    .mysql => const MySqlQueryGrammar(),
  };

  /// Quotes `table.column`, `column as alias`, `table.*` or `*`. Invalid
  /// characters throw instead of being interpolated (never trust input).
  String wrap(Object identifier) {
    if (identifier is RawExpression) {
      return identifier.sql;
    }
    final text = '$identifier';
    final alias = _alias.firstMatch(text);
    if (alias != null) {
      return '${wrap(alias.group(1)!)} AS ${_quote(alias.group(2)!.trim())}';
    }
    return text
        .split('.')
        .map((part) => part == '*' ? '*' : _quote(part))
        .join('.');
  }

  String _quote(String part) {
    final trimmed = part.trim();
    if (!_identifier.hasMatch(trimmed)) {
      throw ArgumentError.value(part, 'identifier', 'Invalid SQL identifier');
    }
    return '$quoteOpen$trimmed$quoteClose';
  }

  // ---------------------------------------------------------------------------
  // SELECT
  // ---------------------------------------------------------------------------

  CompiledQuery compileSelect(QueryAst query) {
    final c = Compilation(this);
    final sql = _select(query, c);
    return CompiledQuery(sql, c.bindings);
  }

  String _select(QueryAst query, Compilation c) {
    final buffer = StringBuffer('SELECT ');
    if (query.distinct) {
      buffer.write('DISTINCT ');
    }
    final aggregate = query.aggregate;
    if (aggregate != null) {
      final column = aggregate.column is RawExpression
          ? c.raw(aggregate.column as RawExpression)
          : wrap(aggregate.column);
      buffer.write(
        '${aggregate.function.toUpperCase()}(${query.distinct ? 'DISTINCT ' : ''}$column) AS ${_quote('aggregate')}',
      );
    } else if (query.columns.isEmpty) {
      buffer.write('*');
    } else {
      buffer.write(
        query.columns
            .map(
              (col) => switch (col) {
                RawExpression() => c.raw(col),
                SubSelect(:final query, :final alias, :final exists) =>
                  '${exists ? 'EXISTS' : ''}(${_select(query, c)}) '
                      'AS ${_quote(alias)}',
                _ => wrap(col),
              },
            )
            .join(', '),
      );
    }
    buffer.write(' FROM ${_from(query, c)}');
    for (final join in query.joins) {
      buffer.write(_join(join, c));
    }
    final where = _wheres(query.wheres, c);
    if (where.isNotEmpty) {
      buffer.write(' WHERE $where');
    }
    if (query.groups.isNotEmpty) {
      buffer.write(
        ' GROUP BY ${query.groups.map((g) => g is RawExpression ? c.raw(g) : wrap(g)).join(', ')}',
      );
    }
    if (query.havings.isNotEmpty) {
      buffer.write(' HAVING ${_havings(query.havings, c)}');
    }
    if (query.unions.isNotEmpty) {
      final base = buffer.toString();
      buffer
        ..clear()
        ..write(wrapUnion(base));
      for (final union in query.unions) {
        buffer.write(
          ' UNION ${union.all ? 'ALL ' : ''}${wrapUnion(_select(union.query, c))}',
        );
      }
    }
    if (query.orders.isNotEmpty && query.aggregate == null) {
      buffer.write(
        ' ORDER BY ${query.orders.map((o) => _order(o, c)).join(', ')}',
      );
    }
    buffer.write(compileLimitOffset(query.limit, query.offset, c));
    buffer.write(lockClause(query.lock));
    return buffer.toString();
  }

  String _from(QueryAst query, Compilation c) {
    final sub = query.fromSubQuery;
    if (sub != null) {
      return '(${_select(sub, c)}) AS ${_quote(query.tableAlias ?? query.table)}';
    }
    final alias = query.tableAlias;
    return alias == null
        ? wrap(query.table)
        : '${wrap(query.table)} AS ${_quote(alias)}';
  }

  String _join(JoinClause join, Compilation c) {
    final keyword = switch (join.type) {
      .inner => 'INNER JOIN',
      .left => 'LEFT JOIN',
      .right => 'RIGHT JOIN',
      .cross => 'CROSS JOIN',
    };
    final sub = join.subQuery;
    final target = sub != null
        ? '(${_select(sub, c)}) AS ${_quote(join.alias ?? join.table)}'
        : join.alias == null
        ? wrap(join.table)
        : '${wrap(join.table)} AS ${_quote(join.alias!)}';
    if (join.conditions.isEmpty) {
      return ' $keyword $target';
    }
    final buffer = StringBuffer(' $keyword $target ON ');
    for (var i = 0; i < join.conditions.length; i++) {
      final cond = join.conditions[i];
      if (i > 0) {
        buffer.write(' ${cond.boolean} ');
      }
      final first = cond.first is RawExpression
          ? c.raw(cond.first as RawExpression)
          : wrap(cond.first);
      final second = cond.isValue ? c.bind(cond.second) : wrap(cond.second!);
      buffer.write('$first ${cond.operator} $second');
    }
    return buffer.toString();
  }

  String _wheres(List<WhereClause> wheres, Compilation c) {
    final buffer = StringBuffer();
    for (var i = 0; i < wheres.length; i++) {
      final where = wheres[i];
      if (i > 0) {
        buffer.write(' ${where.boolean} ');
      }
      buffer.write(_where(where, c));
    }
    return buffer.toString();
  }

  String _where(WhereClause where, Compilation c) => switch (where) {
    BasicWhere(:final column, :final operator, :final value) =>
      '${column is RawExpression ? c.raw(column) : wrap(column)} $operator '
          '${value is RawExpression ? c.raw(value) : c.bind(value)}',
    ColumnWhere(:final first, :final operator, :final second) =>
      '${wrap(first)} $operator ${wrap(second)}',
    InWhere(:final column, :final values, :final subQuery, :final not) => _in(
      column,
      values,
      subQuery,
      not,
      c,
    ),
    NullWhere(:final column, :final not) =>
      '${wrap(column)} IS ${not ? 'NOT ' : ''}NULL',
    BetweenWhere(:final column, :final from, :final to, :final not) =>
      '${wrap(column)} ${not ? 'NOT ' : ''}BETWEEN ${c.bind(from)} AND ${c.bind(to)}',
    NestedWhere(:final wheres, :final not) =>
      '${not ? 'NOT ' : ''}(${_wheres(wheres, c)})',
    ExistsWhere(:final subQuery, :final not) =>
      '${not ? 'NOT ' : ''}EXISTS (${_select(subQuery, c)})',
    RawWhere(:final sql, :final bindings) => c.raw(
      RawExpression(sql, bindings),
    ),
    DatePartWhere(:final column, :final part, :final operator, :final value) =>
      '${datePart(part, wrap(column))} $operator ${c.bind(value)}',
    JsonWhere(
      :final column,
      :final kind,
      :final operator,
      :final value,
      :final not,
    ) =>
      jsonWhere(column, kind, operator, value, not, c),
  };

  String _in(
    String column,
    List<Object?> values,
    QueryAst? subQuery,
    bool not,
    Compilation c,
  ) {
    if (subQuery != null) {
      return '${wrap(column)} ${not ? 'NOT ' : ''}IN (${_select(subQuery, c)})';
    }
    if (values.isEmpty) {
      return not ? '1 = 1' : '0 = 1';
    }
    return '${wrap(column)} ${not ? 'NOT ' : ''}IN (${values.map(c.bind).join(', ')})';
  }

  String _havings(List<HavingClause> havings, Compilation c) {
    final buffer = StringBuffer();
    for (var i = 0; i < havings.length; i++) {
      final having = havings[i];
      if (i > 0) {
        buffer.write(' ${having.boolean} ');
      }
      final raw = having.raw;
      if (raw != null) {
        buffer.write(c.raw(raw));
      } else {
        final column = having.column is RawExpression
            ? c.raw(having.column! as RawExpression)
            : wrap(having.column!);
        buffer.write('$column ${having.operator} ${c.bind(having.value)}');
      }
    }
    return buffer.toString();
  }

  String _order(OrderClause order, Compilation c) {
    final raw = order.raw;
    if (raw != null) {
      return c.raw(raw);
    }
    final column = order.column is RawExpression
        ? c.raw(order.column as RawExpression)
        : wrap(order.column);
    return '$column ${order.direction}';
  }

  /// `LIMIT`/`OFFSET` fragment (MySQL needs a limit when offset is given).
  String compileLimitOffset(int? limit, int? offset, Compilation c) {
    final buffer = StringBuffer();
    if (limit != null) {
      buffer.write(' LIMIT ${c.bind(limit)}');
    }
    if (offset != null) {
      buffer.write(' OFFSET ${c.bind(offset)}');
    }
    return buffer.toString();
  }

  String lockClause(LockMode mode) => switch (mode) {
    .none => '',
    .forUpdate => ' FOR UPDATE',
    .shared => ' FOR SHARE',
  };

  /// Wraps one side of a `UNION` (SQLite cannot parenthesize selects).
  String wrapUnion(String sql) => '($sql)';

  /// Expression extracting [part] from a column (`date`, `year`...).
  String datePart(String part, String column);

  /// JSON where fragment (`contains` / `length`).
  String jsonWhere(
    String column,
    String kind,
    String operator,
    Object? value,
    bool not,
    Compilation c,
  );

  // ---------------------------------------------------------------------------
  // INSERT / UPDATE / DELETE
  // ---------------------------------------------------------------------------

  CompiledQuery compileInsert(
    String table,
    List<Map<String, Object?>> rows, {
    bool ignore = false,
  }) {
    if (rows.isEmpty) {
      throw ArgumentError('insert() requires at least one row.');
    }
    final c = Compilation(this);
    final columns = rows.first.keys.toList();
    for (final (index, row) in rows.indexed) {
      if (row.length != columns.length || !columns.every(row.containsKey)) {
        throw ArgumentError(
          'insert(): row $index has the columns '
          '${row.keys.join(', ')}, not ${columns.join(', ')}. Every row must '
          'name the same columns.',
        );
      }
    }
    final values = rows
        .map(
          (row) => '(${columns.map((col) => _value(row[col], c)).join(', ')})',
        )
        .join(', ');
    final sql =
        '${insertKeyword(ignore)} INTO ${wrap(table)} (${columns.map(wrap).join(', ')}) VALUES $values';
    return CompiledQuery(sql, c.bindings);
  }

  String insertKeyword(bool ignore) => ignore ? 'INSERT OR IGNORE' : 'INSERT';

  /// Insert returning the generated id (`RETURNING` when supported).
  CompiledQuery compileInsertGetId(
    String table,
    Map<String, Object?> row,
    String idColumn,
  ) {
    final base = compileInsert(table, [row]);
    if (!supportsReturning) {
      return base;
    }
    return CompiledQuery(
      '${base.sql} RETURNING ${wrap(idColumn)}',
      base.bindings,
    );
  }

  CompiledQuery compileUpsert(
    String table,
    List<Map<String, Object?>> rows,
    List<String> uniqueBy,
    List<String> update,
  );

  CompiledQuery compileUpdate(QueryAst query, Map<String, Object?> values) {
    final c = Compilation(this);
    final sets = values.entries
        .map((e) => '${wrap(e.key)} = ${_value(e.value, c)}')
        .join(', ');
    final buffer = StringBuffer('UPDATE ${wrap(query.table)} SET $sets');
    final where = _wheres(query.wheres, c);
    if (where.isNotEmpty) {
      buffer.write(' WHERE $where');
    }
    return CompiledQuery(buffer.toString(), c.bindings);
  }

  CompiledQuery compileDelete(QueryAst query) {
    final c = Compilation(this);
    final buffer = StringBuffer('DELETE FROM ${wrap(query.table)}');
    final where = _wheres(query.wheres, c);
    if (where.isNotEmpty) {
      buffer.write(' WHERE $where');
    }
    return CompiledQuery(buffer.toString(), c.bindings);
  }

  CompiledQuery compileTruncate(String table) =>
      CompiledQuery('DELETE FROM ${wrap(table)}', const <Object?>[]);

  CompiledQuery compileExists(QueryAst query) {
    final inner = compileSelect(query);
    return CompiledQuery(
      'SELECT EXISTS(${inner.sql}) AS ${_quote('exists')}',
      inner.bindings,
    );
  }

  String _value(Object? value, Compilation c) =>
      value is RawExpression ? c.raw(value) : c.bind(value);

  /// Dialect name for `value` in upserts (`excluded.col` / `VALUES(col)`).
  String excludedValue(String column) => 'excluded.${wrap(column)}';
}

/// SQLite grammar: `?` placeholders, `INSERT OR IGNORE`, `ON CONFLICT`.
final class SqliteQueryGrammar extends QueryGrammar {
  const SqliteQueryGrammar();

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  String wrapUnion(String sql) => 'SELECT * FROM ($sql)';

  @override
  String parameter(int index) => '?';

  @override
  String lockClause(LockMode mode) => '';

  @override
  String datePart(String part, String column) => switch (part) {
    'date' => "strftime('%Y-%m-%d', $column)",
    'year' => "CAST(strftime('%Y', $column) AS INTEGER)",
    'month' => "CAST(strftime('%m', $column) AS INTEGER)",
    'day' => "CAST(strftime('%d', $column) AS INTEGER)",
    'time' => "strftime('%H:%M:%S', $column)",
    _ => throw ArgumentError.value(part, 'part', 'Unknown date part'),
  };

  @override
  String jsonWhere(
    String column,
    String kind,
    String operator,
    Object? value,
    bool not,
    Compilation c,
  ) {
    if (kind == 'length') {
      return 'json_array_length(${wrap(column)}) $operator ${c.bind(value)}';
    }
    return '${not ? 'NOT ' : ''}EXISTS (SELECT 1 FROM json_each(${wrap(column)}) WHERE json_each.value = ${c.bind(value)})';
  }

  @override
  CompiledQuery compileUpsert(
    String table,
    List<Map<String, Object?>> rows,
    List<String> uniqueBy,
    List<String> update,
  ) {
    final base = compileInsert(table, rows);
    final sets = update
        .map((col) => '${wrap(col)} = ${excludedValue(col)}')
        .join(', ');
    final action = update.isEmpty ? 'DO NOTHING' : 'DO UPDATE SET $sets';
    return CompiledQuery(
      '${base.sql} ON CONFLICT (${uniqueBy.map(wrap).join(', ')}) $action',
      base.bindings,
    );
  }
}

/// PostgreSQL grammar: `$n` placeholders, `RETURNING`, `ON CONFLICT`.
final class PostgresQueryGrammar extends QueryGrammar {
  const PostgresQueryGrammar();

  @override
  SqlDialect get dialect => SqlDialect.postgres;

  @override
  String parameter(int index) => '\$$index';

  @override
  String insertKeyword(bool ignore) => 'INSERT';

  @override
  CompiledQuery compileInsert(
    String table,
    List<Map<String, Object?>> rows, {
    bool ignore = false,
  }) {
    final base = super.compileInsert(table, rows);
    return ignore
        ? CompiledQuery('${base.sql} ON CONFLICT DO NOTHING', base.bindings)
        : base;
  }

  @override
  String datePart(String part, String column) => switch (part) {
    'date' => '$column::date',
    'time' => '$column::time',
    _ => 'EXTRACT($part FROM $column)',
  };

  @override
  String jsonWhere(
    String column,
    String kind,
    String operator,
    Object? value,
    bool not,
    Compilation c,
  ) {
    if (kind == 'length') {
      return 'jsonb_array_length((${wrap(column)})::jsonb) $operator ${c.bind(value)}';
    }
    return '${not ? 'NOT ' : ''}((${wrap(column)})::jsonb @> ${c.bind(value)}::jsonb)';
  }

  @override
  CompiledQuery compileUpsert(
    String table,
    List<Map<String, Object?>> rows,
    List<String> uniqueBy,
    List<String> update,
  ) {
    final base = compileInsert(table, rows);
    final sets = update
        .map((col) => '${wrap(col)} = ${excludedValue(col)}')
        .join(', ');
    final action = update.isEmpty ? 'DO NOTHING' : 'DO UPDATE SET $sets';
    return CompiledQuery(
      '${base.sql} ON CONFLICT (${uniqueBy.map(wrap).join(', ')}) $action',
      base.bindings,
    );
  }

  @override
  CompiledQuery compileTruncate(String table) => CompiledQuery(
    'TRUNCATE TABLE ${wrap(table)} RESTART IDENTITY CASCADE',
    const <Object?>[],
  );
}

/// MySQL/MariaDB grammar: backtick quoting, `?` placeholders, no RETURNING.
final class MySqlQueryGrammar extends QueryGrammar {
  const MySqlQueryGrammar();

  @override
  SqlDialect get dialect => SqlDialect.mysql;

  @override
  String parameter(int index) => '?';

  @override
  String get quoteOpen => '`';

  @override
  String get quoteClose => '`';

  @override
  bool get supportsReturning => false;

  @override
  String insertKeyword(bool ignore) => ignore ? 'INSERT IGNORE' : 'INSERT';

  @override
  String lockClause(LockMode mode) => switch (mode) {
    .none => '',
    .forUpdate => ' FOR UPDATE',
    .shared => ' LOCK IN SHARE MODE',
  };

  @override
  String compileLimitOffset(int? limit, int? offset, Compilation c) {
    if (limit == null && offset != null) {
      return ' LIMIT 18446744073709551615 OFFSET ${c.bind(offset)}';
    }
    return super.compileLimitOffset(limit, offset, c);
  }

  @override
  String datePart(String part, String column) => switch (part) {
    'date' => 'DATE($column)',
    'time' => 'TIME($column)',
    _ => '${part.toUpperCase()}($column)',
  };

  @override
  String jsonWhere(
    String column,
    String kind,
    String operator,
    Object? value,
    bool not,
    Compilation c,
  ) {
    if (kind == 'length') {
      return 'JSON_LENGTH(${wrap(column)}) $operator ${c.bind(value)}';
    }
    return '${not ? 'NOT ' : ''}JSON_CONTAINS(${wrap(column)}, ${c.bind(value)})';
  }

  @override
  String excludedValue(String column) => 'VALUES(${wrap(column)})';

  @override
  CompiledQuery compileUpsert(
    String table,
    List<Map<String, Object?>> rows,
    List<String> uniqueBy,
    List<String> update,
  ) {
    final base = compileInsert(table, rows);
    if (update.isEmpty) {
      final key = wrap(uniqueBy.first);
      return CompiledQuery(
        '${base.sql} ON DUPLICATE KEY UPDATE $key = $key',
        base.bindings,
      );
    }
    final sets = update
        .map((col) => '${wrap(col)} = ${excludedValue(col)}')
        .join(', ');
    return CompiledQuery(
      '${base.sql} ON DUPLICATE KEY UPDATE $sets',
      base.bindings,
    );
  }

  @override
  CompiledQuery compileTruncate(String table) =>
      CompiledQuery('TRUNCATE TABLE ${wrap(table)}', const <Object?>[]);
}
