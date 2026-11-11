part of 'query_ast.dart';

/// A column or table name checked once, where it is made: one or more
/// plain names joined by dots (`email`, `users.id`, `app.users.id`), each
/// `[A-Za-z_][A-Za-z0-9_]*`. Anything else (spaces, quotes, `*`, `->`,
/// `as` aliases) throws an [ArgumentError].
///
/// It implements [String], so every builder method that takes a column
/// accepts it as it accepts a string, and the grammars quote it exactly as
/// they quote the same string: the SQL is byte-identical. Use it where a
/// column name comes from outside the code (a `sort` query parameter); the
/// opt-in lint `prefer_sql_identifier` points out column arguments that
/// are neither a string literal nor a [SqlIdentifier]. A whitelist of
/// allowed columns is still the better check for request input.
///
/// ```dart
/// final sort = SqlIdentifier(request.queryString('sort', 'id'));
/// await DB.table('users').orderBy(sort).get();
/// ```
extension type const SqlIdentifier._(String name) implements String {
  /// [name], validated; throws an [ArgumentError] when it is not one or
  /// more plain names joined by dots.
  factory SqlIdentifier(String name) {
    if (!isValid(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Not a plain SQL identifier (letters, digits, _ and dots)',
      );
    }
    return SqlIdentifier._(name);
  }

  /// [name] as an identifier, or `null` when it is not a valid one.
  static SqlIdentifier? tryParse(String name) =>
      isValid(name) ? SqlIdentifier._(name) : null;

  /// Whether [name] is one or more plain names joined by dots.
  static bool isValid(String name) => _pattern.hasMatch(name);

  static final RegExp _pattern = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$',
  );
}

/// SQL text that the framework inserts as written: the [RawExpression.sql]
/// of `DB.raw(...)`, `selectRaw`, `orderByRaw` and the other raw methods.
///
/// It has no public constructor, so code outside the framework makes one
/// only with an explicit cast (`as SqlFragment`, which extension types
/// cannot forbid); it implements [String], so code that reads
/// `RawExpression.sql` as a string keeps working. The type documents
/// where raw SQL flows; it does not check the text. Values still belong in
/// the bindings, which `no_sql_string_interpolation` enforces.
extension type const SqlFragment._(String sql) implements String {}
