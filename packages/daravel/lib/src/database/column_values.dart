import '../foundation/shared_result.dart';
import 'database_manager.dart';
import 'query_executor.dart';
import 'schema/schema_builder.dart';

/// How a value from a URL meets a column, by the column's database type.
enum ColumnValueKind {
  /// An integer column: the value must be an integer in its range.
  integer,

  /// A decimal or floating-point column: the value must be a plain
  /// decimal (`7`, `-7.5`, `.5`; no exponent).
  decimal,

  /// A text column: any value.
  text,

  /// Anything else (uuid, dates, boolean, enum, json, ...): the value is
  /// compared as it is, and a database that refuses it (PostgreSQL's data
  /// exceptions) means no row.
  other,
}

/// The type of a column as route model binding reads it (`{post:number}`):
/// what a value from the URL must look like to find a row.
///
/// PostgreSQL refuses to compare an integer column with `'abc'` (a `500`),
/// and MySQL compares it as `0`, binding the row whose number is 0. The
/// value is therefore read first, as PostgreSQL reads an integer (spaces
/// around it, a sign, leading zeros), and one it cannot read finds no row,
/// on every database alike.
final class ColumnValueType {
  /// A column of [kind]; an integer column holds [min] to [max].
  const ColumnValueType(this.kind, {this.min, this.max});

  /// How a value meets the column.
  final ColumnValueKind kind;

  /// The smallest integer the column holds.
  final int? min;

  /// The largest integer the column holds. A MySQL `bigint unsigned` holds
  /// up to 2^64 - 1, but a Dart `int` only up to 2^63 - 1: a value above
  /// that is a 404.
  final int? max;

  /// The longest plain decimal read for a decimal column; any longer value
  /// finds no row (and would not fit a `double precision` column).
  static const int maxDecimalLength = 64;

  static const int _int64Max = 0x7fffffffffffffff;
  static const int _int64Min = -0x8000000000000000;

  /// The column type [type], as `Schema.getColumns` reports it on
  /// [dialect] (`integer`, `bigint unsigned`, `numeric(8,2)`,
  /// `character varying(255)`, ...).
  factory ColumnValueType.of(String type, SqlDialect dialect) {
    final lower = type.toLowerCase().trim();
    if (lower.contains('[')) {
      return const ColumnValueType(ColumnValueKind.other); // An array.
    }
    final base = lower.split(RegExp('[ (]')).first;
    final bits = switch (base) {
      'tinyint' => 8,
      'smallint' || 'int2' => 16,
      'mediumint' => 24,
      'int' || 'integer' || 'int4' || 'serial' => 32,
      'bigint' || 'int8' || 'bigserial' => 64,
      _ => null,
    };
    if (bits != null) {
      // SQLite stores any integer in 64 bits, whatever the declared type.
      if (dialect == SqlDialect.sqlite || bits == 64) {
        return lower.contains('unsigned')
            ? const ColumnValueType(.integer, min: 0, max: _int64Max)
            : const ColumnValueType(.integer, min: _int64Min, max: _int64Max);
      }
      return lower.contains('unsigned')
          ? ColumnValueType(.integer, min: 0, max: (1 << bits) - 1)
          : ColumnValueType(
              .integer,
              min: -(1 << (bits - 1)),
              max: (1 << (bits - 1)) - 1,
            );
    }
    return switch (base) {
      'decimal' ||
      'numeric' ||
      'real' ||
      'float' ||
      'float4' ||
      'float8' ||
      'double' => const ColumnValueType(.decimal),
      'char' ||
      'character' ||
      'varchar' ||
      'nchar' ||
      'nvarchar' ||
      'text' ||
      'tinytext' ||
      'mediumtext' ||
      'longtext' ||
      'citext' ||
      'clob' => const ColumnValueType(.text),
      _ => const ColumnValueType(.other),
    };
  }

  /// The value to compare the column with for [value] from the URL, or
  /// `null` when no row can match it.
  Object? parse(String value) => switch (kind) {
    .integer => _integer(value),
    .decimal => _decimal(value),
    .text || .other => value,
  };

  // PostgreSQL's isspace(): space, \t, \n, \v, \f, \r.
  static bool _space(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0d);

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  /// [value] trimmed of spaces, as `(start, end)`.
  static (int, int) _trimmed(String value) {
    var start = 0;
    var end = value.length;
    while (start < end && _space(value.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _space(value.codeUnitAt(end - 1))) {
      end--;
    }
    return (start, end);
  }

  /// One pass: spaces, a sign, digits, spaces; then the range.
  int? _integer(String value) {
    var (start, end) = _trimmed(value);
    var negative = false;
    if (start < end) {
      final c = value.codeUnitAt(start);
      if (c == 0x2b || c == 0x2d) {
        negative = c == 0x2d;
        start++;
      }
    }
    if (start == end) {
      return null;
    }
    for (var i = start; i < end; i++) {
      if (!_digit(value.codeUnitAt(i))) {
        return null;
      }
    }
    while (start < end - 1 && value.codeUnitAt(start) == 0x30) {
      start++; // Leading zeros.
    }
    if (end - start > 19) {
      return null; // Beyond any 64-bit integer.
    }
    final digits = value.substring(start, end);
    final parsed = int.tryParse(negative ? '-$digits' : digits);
    if (parsed == null ||
        (min != null && parsed < min!) ||
        (max != null && parsed > max!)) {
      return null;
    }
    return parsed;
  }

  /// One pass: spaces, a sign, digits with at most one point, spaces. The
  /// value is bound as text, so a `numeric` column keeps every digit.
  String? _decimal(String value) {
    final (start, end) = _trimmed(value);
    if (end - start > maxDecimalLength) {
      return null;
    }
    var at = start;
    if (at < end) {
      final c = value.codeUnitAt(at);
      if (c == 0x2b || c == 0x2d) {
        at++;
      }
    }
    var digits = 0;
    var point = false;
    for (; at < end; at++) {
      final c = value.codeUnitAt(at);
      if (_digit(c)) {
        digits++;
      } else if (c == 0x2e && !point) {
        point = true;
      } else {
        return null;
      }
    }
    return digits == 0 ? null : value.substring(start, end);
  }
}

/// The column types of the tables route model binding reads, from
/// `Schema.getColumns`: one query per connection and table, kept per
/// [DatabaseManager] (so per isolate) until the schema changes.
///
/// A [SchemaBuilder] of this isolate that creates, alters, renames or
/// drops a table (migrations, `refreshDatabase`) clears them. A change made
/// another way (raw SQL, another process) is seen after a restart.
abstract final class ColumnValueTypes {
  // Shared by the requests of the isolate, each in an error zone of its
  // own: a SharedResult, so a failed read reaches every one of them.
  static final Expando<
    Map<String, (int, SharedResult<Map<String, ColumnValueType>>)>
  >
  _byManager = Expando();

  /// The type of [column] of [table] on [connection] of [manager], or
  /// `null` when the database does not report it (a view, a missing
  /// column). Route model binding then compares the value as it is, as
  /// before these types were read, and a data exception from the lookup
  /// (SQLSTATE class 22) is still a 404; on MySQL a word compared with an
  /// integer column of such a table is then read as 0, as in Laravel.
  /// [table] is the
  /// name the query uses (Daravel has no connection table prefix);
  /// `schema.table` reads that schema's table.
  static Future<ColumnValueType?> of(
    DatabaseManager manager,
    String? connection,
    String table,
    String column,
  ) async {
    final name = connection ?? manager.config.defaultConnection;
    final cache = _byManager[manager] ??= {};
    final key = '$name\u0000$table';
    final cached = cache[key];
    final version = SchemaBuilder.changes;
    final SharedResult<Map<String, ColumnValueType>> types;
    if (cached != null && cached.$1 == version) {
      types = cached.$2;
    } else {
      types = SharedResult(() => _load(manager, connection, table));
      cache[key] = (version, types);
    }
    try {
      return (await types.value)[column];
    } on Object {
      // Not cached: the next request asks again.
      if (identical(cache[key]?.$2, types)) {
        cache.remove(key);
      }
      rethrow;
    }
  }

  static Future<Map<String, ColumnValueType>> _load(
    DatabaseManager manager,
    String? connection,
    String table,
  ) async {
    final executor = await manager.executor(connection);
    final columns = await SchemaBuilder(executor).getColumns(table);
    return {
      for (final column in columns)
        column.name: ColumnValueType.of(column.type, executor.dialect),
    };
  }
}
