/// Raw SQL fragment with its own bindings; inserted verbatim by grammars.
final class RawExpression {
  const RawExpression(this.sql, [this.bindings = const <Object?>[]]);

  final String sql;
  final List<Object?> bindings;

  @override
  String toString() => sql;
}

/// Row-lock modes.
enum LockMode { none, forUpdate, shared }

/// Join types.
enum JoinType { inner, left, right, cross }

/// One `ON` condition of a join.
final class JoinCondition {
  const JoinCondition({
    required this.first,
    required this.operator,
    required this.second,
    this.boolean = 'AND',
    this.isValue = false,
  });

  /// Left side column (or raw expression).
  final Object first;
  final String operator;

  /// Right side: a column (default) or, when [isValue], a bound value.
  final Object? second;
  final String boolean;
  final bool isValue;
}

/// A join clause.
final class JoinClause {
  JoinClause({
    required this.type,
    required this.table,
    this.alias,
    this.subQuery,
  });

  final JoinType type;
  final String table;
  final String? alias;
  final QueryAst? subQuery;
  final List<JoinCondition> conditions = <JoinCondition>[];
}

/// Where clauses (sealed so grammars can be exhaustive).
sealed class WhereClause {
  const WhereClause({this.boolean = 'AND'});

  /// `AND` / `OR` connector to the previous clause.
  final String boolean;
}

final class BasicWhere extends WhereClause {
  const BasicWhere(this.column, this.operator, this.value, {super.boolean});
  final Object column;
  final String operator;
  final Object? value;
}

final class ColumnWhere extends WhereClause {
  const ColumnWhere(this.first, this.operator, this.second, {super.boolean});
  final String first;
  final String operator;
  final String second;
}

final class InWhere extends WhereClause {
  const InWhere(
    this.column,
    this.values, {
    this.not = false,
    this.subQuery,
    super.boolean,
  });
  final String column;
  final List<Object?> values;
  final QueryAst? subQuery;
  final bool not;
}

final class NullWhere extends WhereClause {
  const NullWhere(this.column, {this.not = false, super.boolean});
  final String column;
  final bool not;
}

final class BetweenWhere extends WhereClause {
  const BetweenWhere(
    this.column,
    this.from,
    this.to, {
    this.not = false,
    super.boolean,
  });
  final String column;
  final Object? from;
  final Object? to;
  final bool not;
}

final class NestedWhere extends WhereClause {
  const NestedWhere(this.wheres, {super.boolean});
  final List<WhereClause> wheres;
}

final class ExistsWhere extends WhereClause {
  const ExistsWhere(this.subQuery, {this.not = false, super.boolean});
  final QueryAst subQuery;
  final bool not;
}

final class RawWhere extends WhereClause {
  const RawWhere(
    this.sql, [
    this.bindings = const <Object?>[],
    String boolean = 'AND',
  ]) : super(boolean: boolean);
  final String sql;
  final List<Object?> bindings;
}

/// `whereDate/Month/Day/Year/Time`.
final class DatePartWhere extends WhereClause {
  const DatePartWhere(
    this.column,
    this.part,
    this.operator,
    this.value, {
    super.boolean,
  });
  final String column;

  /// `date`, `year`, `month`, `day`, `time`.
  final String part;
  final String operator;
  final Object? value;
}

/// `whereJsonContains` / `whereJsonLength` (dialect specific).
final class JsonWhere extends WhereClause {
  const JsonWhere(
    this.column,
    this.kind,
    this.operator,
    this.value, {
    this.not = false,
    super.boolean,
  });
  final String column;

  /// `contains` | `length`.
  final String kind;
  final String operator;
  final Object? value;
  final bool not;
}

/// `ORDER BY` entry.
final class OrderClause {
  const OrderClause(this.column, this.direction, {this.raw});
  final Object column;
  final String direction;
  final RawExpression? raw;
}

/// `HAVING` entry.
final class HavingClause {
  const HavingClause(
    this.column,
    this.operator,
    this.value, {
    this.boolean = 'AND',
    this.raw,
  });
  final Object? column;
  final String? operator;
  final Object? value;
  final String boolean;
  final RawExpression? raw;
}

/// `UNION` entry.
final class UnionClause {
  const UnionClause(this.query, {this.all = false});
  final QueryAst query;
  final bool all;
}

/// Aggregate request (`count`, `sum`...).
final class AggregateClause {
  const AggregateClause(this.function, this.column);
  final String function;
  final Object column;
}

/// Dialect-neutral description of a query, compiled by a `QueryGrammar`.
final class QueryAst {
  QueryAst(this.table);

  String table;
  String? tableAlias;
  QueryAst? fromSubQuery;
  final List<Object> columns = <Object>[];
  bool distinct = false;
  final List<JoinClause> joins = <JoinClause>[];
  final List<WhereClause> wheres = <WhereClause>[];
  final List<Object> groups = <Object>[];
  final List<HavingClause> havings = <HavingClause>[];
  final List<OrderClause> orders = <OrderClause>[];
  int? limit;
  int? offset;
  LockMode lock = LockMode.none;
  final List<UnionClause> unions = <UnionClause>[];
  AggregateClause? aggregate;

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
