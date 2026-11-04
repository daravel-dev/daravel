/// The structural SQL tokens a query may carry from its caller: the
/// comparison operator and the `AND`/`OR` between conditions. They are
/// written into the SQL text, not bound, so each is checked against a fixed
/// list: in the builder, where the caller passes it, and again in the
/// grammar, where it is written, so a hand-built AST cannot carry one
/// either. Structural arguments are whitelisted; values are bound. Not
/// exported from the barrel.
abstract final class SqlTokens {
  /// The comparison operators a query may write, in upper case.
  static const Set<String> operators = {
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

  /// Whether [value] is one of [operators], case-insensitively.
  static bool isOperator(String value) =>
      operators.contains(value.toUpperCase());

  /// [value] in upper case, `!=` as `<>`; anything not in [operators]
  /// throws an [ArgumentError].
  static String operator(String value) {
    final upper = value.toUpperCase();
    if (!operators.contains(upper)) {
      throw ArgumentError.value(value, 'operator', 'Unsupported SQL operator');
    }
    return upper == '!=' ? '<>' : upper;
  }

  /// `AND` or `OR` for [value] in any case; anything else throws an
  /// [ArgumentError].
  static String boolean(String value) => switch (value.toUpperCase()) {
    'AND' => 'AND',
    'OR' => 'OR',
    _ => throw ArgumentError.value(
      value,
      'boolean',
      'A condition is joined with AND or OR',
    ),
  };
}
