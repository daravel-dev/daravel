/// Expands raw SQL bindings into a dialect's placeholders without touching
/// string literals, comments, `::casts` or PostgreSQL JSON operators
/// (ADR-005).
///
/// Supported styles:
/// - positional `?` with a `List` of values;
/// - named `:name` with a `Map` (a name may repeat; `::` casts and `:` inside
///   literals are left alone).
final class SqlBindings {
  const SqlBindings._();

  static final RegExp _nameStart = RegExp(r'[A-Za-z_]');
  static final RegExp _nameChar = RegExp(r'[A-Za-z0-9_]');

  /// Returns the SQL with placeholders rewritten by [placeholder] (1-based
  /// index) and the ordered bindings list.
  static (String, List<Object?>) expand(
    String sql,
    Object? bindings,
    String Function(int index) placeholder,
  ) {
    final positional = bindings is List<Object?> ? bindings : null;
    final named = bindings is Map<String, Object?> ? bindings : null;
    final out = StringBuffer();
    final values = <Object?>[];
    var positionalIndex = 0;
    var i = 0;
    while (i < sql.length) {
      final char = sql[i];
      // String literals and quoted identifiers are copied verbatim.
      if (char == "'" || char == '"' || char == '`') {
        final end = _closingQuote(sql, i, char);
        out.write(sql.substring(i, end));
        i = end;
        continue;
      }
      // Line and block comments.
      if (char == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
        final end = sql.indexOf('\n', i);
        final stop = end == -1 ? sql.length : end;
        out.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      if (char == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
        final end = sql.indexOf('*/', i + 2);
        final stop = end == -1 ? sql.length : end + 2;
        out.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      if (char == '?' && positional != null) {
        // `?|`, `?&` and `?` followed by space+identifier are JSON operators
        // only when no positional bindings remain; otherwise treat as a slot.
        if (positionalIndex < positional.length) {
          values.add(positional[positionalIndex++]);
          out.write(placeholder(values.length));
          i++;
          continue;
        }
      }
      if (char == ':' && named != null) {
        final isCast = i + 1 < sql.length && sql[i + 1] == ':';
        final prevIsColon = i > 0 && sql[i - 1] == ':';
        if (!isCast &&
            !prevIsColon &&
            i + 1 < sql.length &&
            _nameStart.hasMatch(sql[i + 1])) {
          var end = i + 1;
          while (end < sql.length && _nameChar.hasMatch(sql[end])) {
            end++;
          }
          final name = sql.substring(i + 1, end);
          if (named.containsKey(name)) {
            values.add(named[name]);
            out.write(placeholder(values.length));
            i = end;
            continue;
          }
        }
      }
      out.write(char);
      i++;
    }
    if (positional != null && positionalIndex != positional.length) {
      throw ArgumentError(
        'SQL expects $positionalIndex positional binding(s) but ${positional.length} were given.',
      );
    }
    return (out.toString(), values);
  }

  static int _closingQuote(String sql, int start, String quote) {
    var i = start + 1;
    while (i < sql.length) {
      if (sql[i] == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          i += 2; // escaped quote ('')
          continue;
        }
        return i + 1;
      }
      i++;
    }
    return sql.length;
  }
}
