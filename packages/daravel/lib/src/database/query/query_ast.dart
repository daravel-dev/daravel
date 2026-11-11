part 'sql_types.dart';

/// A subquery in the select list: `(SELECT ...) AS alias`, or
/// `EXISTS(SELECT ...) AS alias` when [exists]. Compiled in the same pass as
/// the outer query, so dialects with numbered placeholders stay in order.
final class SubSelect {
  /// Selects [query] as the column [alias], or `EXISTS(query)` when [exists].
  const SubSelect(this.query, this.alias, {this.exists = false});

  /// The inner query.
  final QueryAst query;

  /// The name of the resulting column.
  final String alias;

  /// Whether the column is `EXISTS(query)` rather than the query's value.
  final bool exists;
}

/// Raw SQL fragment with its own bindings; inserted verbatim by grammars.
final class RawExpression {
  /// The SQL fragment [sql] with `?` placeholders filled by [bindings]:
  /// `DB.raw('price * ?', [1.1])`. Never interpolate input into [sql].
  const RawExpression(String sql, [this.bindings = const <Object?>[]])
    : _sql = sql;

  final String _sql;

  /// The SQL, inserted as written. A [SqlFragment], which is a [String].
  SqlFragment get sql => SqlFragment._(_sql);

  /// The values of the `?` placeholders in [sql], in order.
  final List<Object?> bindings;

  @override
  String toString() => sql;
}

/// Row-lock modes.
enum LockMode {
  /// No row lock.
  none,

  /// `FOR UPDATE` (`lockForUpdate()`).
  forUpdate,

  /// A shared lock (`sharedLock()`).
  shared,
}

/// Join types.
enum JoinType {
  /// `INNER JOIN`: rows with a match on both sides.
  inner,

  /// `LEFT JOIN`: every row of the left side.
  left,

  /// `RIGHT JOIN`: every row of the right side.
  right,

  /// `CROSS JOIN`: every combination.
  cross,
}

/// One `ON` condition of a join.
final class JoinCondition {
  /// An `ON` condition: `first operator second`, joined to the previous
  /// condition with [boolean].
  const JoinCondition({
    required this.first,
    required this.operator,
    required this.second,
    this.boolean = 'AND',
    this.isValue = false,
  });

  /// Left side column (or raw expression).
  final Object first;

  /// The comparison operator, such as `=` or `<`.
  final String operator;

  /// Right side: a column (default) or, when [isValue], a bound value.
  final Object? second;

  /// `AND` or `OR`: how the condition joins the one before.
  final String boolean;

  /// Whether [second] is a bound value rather than a column.
  final bool isValue;
}

/// A join clause.
final class JoinClause {
  /// A join of [type] with [table] (as [alias]), or with [subQuery].
  JoinClause({
    required this.type,
    required this.table,
    this.alias,
    this.subQuery,
  });

  /// Inner, left, right or cross.
  final JoinType type;

  /// The joined table, or the alias of a joined subquery.
  final String table;

  /// The alias of the joined table.
  final String? alias;

  /// The joined subquery (`joinSub`), when there is one.
  final QueryAst? subQuery;

  /// The `ON` conditions, in order.
  final List<JoinCondition> conditions = <JoinCondition>[];
}

/// Where clauses (sealed so grammars can be exhaustive).
sealed class WhereClause {
  /// A condition joined to the previous one with [boolean].
  const WhereClause({this.boolean = 'AND'});

  /// `AND` / `OR` connector to the previous clause.
  final String boolean;
}

/// `column operator value` (`where('votes', '>', 100)`).
final class BasicWhere extends WhereClause {
  /// Compares [column] with the bound [value] using [operator].
  const BasicWhere(
    this.column,
    this.operator,
    this.value, {
    super.boolean,
    this.escaped = false,
  });

  /// The column name, or a [RawExpression].
  final Object column;

  /// The comparison operator, such as `=`, `<>` or `LIKE`.
  final String operator;

  /// The bound value.
  final Object? value;

  /// Whether [value] is a `LIKE` pattern escaped with [likeEscape], so the
  /// SQL adds `ESCAPE '!'` (a typed column's `startsWith`, `endsWith` and
  /// `contains`).
  final bool escaped;

  /// The `LIKE` escape character: the same on SQLite, PostgreSQL and MySQL
  /// (whatever `NO_BACKSLASH_ESCAPES` says), unlike a backslash.
  static const String likeEscape = '!';

  /// [text] with the `LIKE` wildcards `%` and `_` (and [likeEscape]
  /// itself) escaped, to match literally inside an [escaped] pattern.
  static String escapeLike(String text) =>
      text.replaceAllMapped(RegExp('[!%_]'), (m) => '$likeEscape${m[0]}');
}

/// `first operator second` between two columns (`whereColumn`).
final class ColumnWhere extends WhereClause {
  /// Compares the columns [first] and [second] using [operator].
  const ColumnWhere(this.first, this.operator, this.second, {super.boolean});

  /// The left column.
  final String first;

  /// The comparison operator.
  final String operator;

  /// The right column.
  final String second;
}

/// `column [NOT] IN (...)` (`whereIn`, `whereNotIn`).
final class InWhere extends WhereClause {
  /// [column] in [values], or in the rows of [subQuery].
  const InWhere(
    this.column,
    this.values, {
    this.not = false,
    this.subQuery,
    super.boolean,
  });

  /// The tested column.
  final String column;

  /// The listed values; empty when [subQuery] is set.
  final List<Object?> values;

  /// A subquery giving the values, when there is one.
  final QueryAst? subQuery;

  /// Whether it is `NOT IN`.
  final bool not;
}

/// `column IS [NOT] NULL` (`whereNull`, `whereNotNull`).
final class NullWhere extends WhereClause {
  /// [column] is null, or not null when [not].
  const NullWhere(this.column, {this.not = false, super.boolean});

  /// The tested column.
  final String column;

  /// Whether it is `IS NOT NULL`.
  final bool not;
}

/// `column [NOT] BETWEEN from AND to` (`whereBetween`).
final class BetweenWhere extends WhereClause {
  /// [column] between [from] and [to], inclusive.
  const BetweenWhere(
    this.column,
    this.from,
    this.to, {
    this.not = false,
    super.boolean,
  });

  /// The tested column.
  final String column;

  /// The lower bound.
  final Object? from;

  /// The upper bound.
  final Object? to;

  /// Whether it is `NOT BETWEEN`.
  final bool not;
}

/// A parenthesized group of conditions (`where((q) => ...)`, `whereNot`).
final class NestedWhere extends WhereClause {
  /// The group [wheres], negated when [not].
  const NestedWhere(this.wheres, {this.not = false, super.boolean});

  /// The conditions inside the parentheses.
  final List<WhereClause> wheres;

  /// `NOT (...)` (`whereNot`).
  final bool not;
}

/// `[NOT] EXISTS (subquery)` (`whereExists`).
final class ExistsWhere extends WhereClause {
  /// Whether [subQuery] returns a row, or none when [not].
  const ExistsWhere(this.subQuery, {this.not = false, super.boolean});

  /// The tested subquery.
  final QueryAst subQuery;

  /// Whether it is `NOT EXISTS`.
  final bool not;
}

/// A raw condition with bindings (`whereRaw`).
final class RawWhere extends WhereClause {
  /// The condition [sql] with `?` [bindings].
  const RawWhere(
    this.sql, [
    this.bindings = const <Object?>[],
    String boolean = 'AND',
  ]) : super(boolean: boolean);

  /// The SQL, inserted as written.
  final String sql;

  /// The values of the `?` placeholders.
  final List<Object?> bindings;
}

/// `whereDate/Month/Day/Year/Time`.
final class DatePartWhere extends WhereClause {
  /// Compares a [part] of the date in [column] with [value].
  const DatePartWhere(
    this.column,
    this.part,
    this.operator,
    this.value, {
    super.boolean,
  });

  /// The date or datetime column.
  final String column;

  /// `date`, `year`, `month`, `day`, `time`.
  final String part;

  /// The comparison operator.
  final String operator;

  /// The compared value: a date string, or a number for year, month, day.
  final Object? value;
}

/// `whereJsonContains` / `whereJsonLength` (dialect specific).
final class JsonWhere extends WhereClause {
  /// A JSON condition of [kind] on [column], compiled per dialect.
  const JsonWhere(
    this.column,
    this.kind,
    this.operator,
    this.value, {
    this.not = false,
    super.boolean,
  });

  /// The JSON column, optionally with a `->` path.
  final String column;

  /// `contains` | `length`.
  final String kind;

  /// The comparison operator, for `length`.
  final String operator;

  /// The value contained, or the length compared.
  final Object? value;

  /// Whether the condition is negated.
  final bool not;
}

/// `ORDER BY` entry.
final class OrderClause {
  /// Orders by [column] in [direction], or by the [raw] expression.
  const OrderClause(this.column, this.direction, {this.raw});

  /// The column, or a [RawExpression]; empty with [raw].
  final Object column;

  /// `ASC` or `DESC`.
  final String direction;

  /// A raw `ORDER BY` expression, when there is one.
  final RawExpression? raw;
}

/// `HAVING` entry.
final class HavingClause {
  /// A `HAVING` condition, or a [raw] one.
  const HavingClause(
    this.column,
    this.operator,
    this.value, {
    this.boolean = 'AND',
    this.raw,
  });

  /// The column or aggregate alias compared.
  final Object? column;

  /// The comparison operator.
  final String? operator;

  /// The compared value.
  final Object? value;

  /// `AND` or `OR`: how it joins the condition before.
  final String boolean;

  /// A raw `HAVING` expression, when there is one.
  final RawExpression? raw;
}

/// `UNION` entry.
final class UnionClause {
  /// Appends [query] with `UNION`, or `UNION ALL` when [all].
  const UnionClause(this.query, {this.all = false});

  /// The appended query.
  final QueryAst query;

  /// Whether duplicates are kept (`UNION ALL`).
  final bool all;
}

/// Aggregate request (`count`, `sum`...).
final class AggregateClause {
  /// An aggregate [function] over [column].
  const AggregateClause(this.function, this.column);

  /// `count`, `sum`, `avg`, `min` or `max`.
  final String function;

  /// The aggregated column, `*` for every row.
  final Object column;
}

/// Dialect-neutral description of a query, compiled by a `QueryGrammar`.
final class QueryAst {
  /// An empty query on [table].
  QueryAst(this.table);

  /// The table queried.
  String table;

  /// The alias of [table], when there is one.
  String? tableAlias;

  /// A subquery used as the table (`fromSub`), when there is one.
  QueryAst? fromSubQuery;

  /// The selected columns; empty means `*`.
  final List<Object> columns = <Object>[];

  /// Whether the query is `SELECT DISTINCT`.
  bool distinct = false;

  /// The joins, in order.
  final List<JoinClause> joins = <JoinClause>[];

  /// The `WHERE` conditions, in order.
  final List<WhereClause> wheres = <WhereClause>[];

  /// The `GROUP BY` columns.
  final List<Object> groups = <Object>[];

  /// The `HAVING` conditions.
  final List<HavingClause> havings = <HavingClause>[];

  /// The `ORDER BY` entries.
  final List<OrderClause> orders = <OrderClause>[];

  /// The row limit, or null for none.
  int? limit;

  /// The rows skipped, or null for none.
  int? offset;

  /// The row lock.
  LockMode lock = LockMode.none;

  /// The queries appended with `UNION`.
  final List<UnionClause> unions = <UnionClause>[];

  /// The aggregate the query computes, when it is an aggregate query.
  AggregateClause? aggregate;

  /// A copy whose lists can change without touching this one.
  QueryAst clone() {
    final copy = QueryAst(table)
      ..tableAlias = tableAlias
      ..fromSubQuery = fromSubQuery?.clone()
      ..distinct = distinct
      ..limit = limit
      ..offset = offset
      ..lock = lock
      ..aggregate = aggregate;
    copy.columns.addAll(columns);
    for (final join in joins) {
      copy.joins.add(
        JoinClause(
          type: join.type,
          table: join.table,
          alias: join.alias,
          subQuery: join.subQuery?.clone(),
        )..conditions.addAll(join.conditions),
      );
    }
    copy.wheres.addAll(wheres);
    copy.groups.addAll(groups);
    copy.havings.addAll(havings);
    copy.orders.addAll(orders);
    copy.unions.addAll(unions);
    return copy;
  }
}
