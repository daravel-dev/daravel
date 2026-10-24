import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../database/database_manager.dart';
import 'rule.dart';

/// Factory facade for built-in rules (`Rule.required()`, `Rule.email()`...).
/// Each factory returns a `const`-friendly [Rule] subclass that can be
/// introspected for messages and OpenAPI hints.
abstract final class Rules {
  static Rule required() => const RequiredRule();
  static Rule nullable() => const NullableRule();
  static Rule sometimes() => const SometimesRule();
  static Rule bail() => const BailRule();
  static Rule present() => const PresentRule();
  static Rule filled() => const FilledRule();
  static Rule prohibited() => const ProhibitedRule();
  static Rule requiredIf(String other, Object? value) =>
      RequiredIfRule(other, value);
  static Rule requiredUnless(String other, Object? value) =>
      RequiredUnlessRule(other, value);
  static Rule requiredWith(List<String> others) => RequiredWithRule(others);
  static Rule requiredWithout(List<String> others) =>
      RequiredWithoutRule(others);
  static Rule string() => const StringRule();
  static Rule integer() => const IntegerRule();
  static Rule numeric() => const NumericRule();
  static Rule boolean() => const BooleanRule();
  static Rule list() => const ListRule();
  static Rule map() => const MapRule();
  static Rule email() => const EmailRule();
  static Rule url() => const UrlRule();
  static Rule uuid() => const UuidRule();
  static Rule ulid() => const UlidRule();
  static Rule ip() => const IpRule();
  static Rule ipv4() => const IpRule(version: 4);
  static Rule ipv6() => const IpRule(version: 6);
  static Rule json() => const JsonRule();
  static Rule alpha() => const AlphaRule();
  static Rule alphaNum() => const AlphaNumRule();
  static Rule alphaDash() => const AlphaDashRule();
  static Rule ascii() => const AsciiRule();
  static Rule lowercase() => const LowercaseRule();
  static Rule uppercase() => const UppercaseRule();
  static Rule regex(RegExp pattern) => RegexRule(pattern);
  static Rule notRegex(RegExp pattern) => RegexRule(pattern, negate: true);
  static Rule min(num value) => MinRule(value);
  static Rule max(num value) => MaxRule(value);
  static Rule between(num min, num max) => BetweenRule(min, max);
  static Rule size(num value) => SizeRule(value);
  static Rule digits(int length) => DigitsRule(length);
  static Rule digitsBetween(int min, int max) => DigitsBetweenRule(min, max);
  static Rule inList(List<Object?> values) => InRule(values);
  static Rule notIn(List<Object?> values) => InRule(values, negate: true);
  static Rule enumValues<E extends Enum>(List<E> values) =>
      InRule(values.map((v) => v.name).toList());
  static Rule distinct() => const DistinctRule();
  static Rule confirmed([String? field]) => ConfirmedRule(field);
  static Rule same(String other) => SameRule(other);
  static Rule different(String other) => SameRule(other, negate: true);
  static Rule startsWith(List<String> prefixes) => StartsWithRule(prefixes);
  static Rule endsWith(List<String> suffixes) => EndsWithRule(suffixes);
  static Rule date() => const DateRule();
  static Rule after(String dateOrField) =>
      DateCompareRule('after', dateOrField);
  static Rule afterOrEqual(String dateOrField) =>
      DateCompareRule('after_or_equal', dateOrField);
  static Rule before(String dateOrField) =>
      DateCompareRule('before', dateOrField);
  static Rule beforeOrEqual(String dateOrField) =>
      DateCompareRule('before_or_equal', dateOrField);
  static Rule unique(
    String table, [
    String? column,
    Object? ignore,
    String idColumn = 'id',
  ]) => UniqueRule(table, column: column, ignore: ignore, idColumn: idColumn);
  static Rule exists(String table, [String? column]) =>
      ExistsRule(table, column: column);
  static Rule password({
    int min = 8,
    bool letters = false,
    bool mixedCase = false,
    bool numbers = false,
    bool symbols = false,
  }) => PasswordRule(
    min: min,
    letters: letters,
    mixedCase: mixedCase,
    numbers: numbers,
    symbols: symbols,
  );
  static Rule custom(
    FutureOr<String?> Function(ValidationContext context) check, {
    String name = 'custom',
  }) => ClosureRule(check, name: name);
}

// ---------------------------------------------------------------------------
// Presence
// ---------------------------------------------------------------------------

final class RequiredRule extends Rule {
  const RequiredRule();
  @override
  String get name => 'required';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get schemaHint => const {'required': true};
  @override
  String? passes(ValidationContext c) =>
      isEmptyValue(c.value) ? 'required' : null;
}

final class PresentRule extends Rule {
  const PresentRule();
  @override
  String get name => 'present';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) => c.present ? null : 'present';
}

final class FilledRule extends Rule {
  const FilledRule();
  @override
  String get name => 'filled';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) =>
      c.present && isEmptyValue(c.value) ? 'filled' : null;
}

final class ProhibitedRule extends Rule {
  const ProhibitedRule();
  @override
  String get name => 'prohibited';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) =>
      c.present && !isEmptyValue(c.value) ? 'prohibited' : null;
}

final class RequiredIfRule extends Rule {
  const RequiredIfRule(this.other, this.expected);
  final String other;
  final Object? expected;
  @override
  String get name => 'required_if';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {'other': other, 'value': expected};
  @override
  String? passes(ValidationContext c) {
    if ('${c.root(other)}' == '$expected' && isEmptyValue(c.value)) {
      return 'required_if';
    }
    return null;
  }
}

final class RequiredUnlessRule extends Rule {
  const RequiredUnlessRule(this.other, this.expected);
  final String other;
  final Object? expected;
  @override
  String get name => 'required_unless';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {'other': other, 'values': expected};
  @override
  String? passes(ValidationContext c) {
    if ('${c.root(other)}' != '$expected' && isEmptyValue(c.value)) {
      return 'required_unless';
    }
    return null;
  }
}

final class RequiredWithRule extends Rule {
  const RequiredWithRule(this.others);
  final List<String> others;
  @override
  String get name => 'required_with';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {'values': others.join(', ')};
  @override
  String? passes(ValidationContext c) {
    final anyPresent = others.any((o) => !isEmptyValue(c.root(o)));
    return anyPresent && isEmptyValue(c.value) ? 'required_with' : null;
  }
}

final class RequiredWithoutRule extends Rule {
  const RequiredWithoutRule(this.others);
  final List<String> others;
  @override
  String get name => 'required_without';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {'values': others.join(', ')};
  @override
  String? passes(ValidationContext c) {
    final anyMissing = others.any((o) => isEmptyValue(c.root(o)));
    return anyMissing && isEmptyValue(c.value) ? 'required_without' : null;
  }
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

final class StringRule extends Rule {
  const StringRule();
  @override
  String get name => 'string';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'string'};
  @override
  String? passes(ValidationContext c) => c.value is String ? null : 'string';
}

final class IntegerRule extends Rule {
  const IntegerRule();
  @override
  String get name => 'integer';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'integer'};
  @override
  String? passes(ValidationContext c) =>
      asInt(c.value) == null ? 'integer' : null;

  /// Parses ints and integral strings (`"42"`), Laravel style.
  static int? asInt(Object? value) => switch (value) {
    int() => value,
    double() when value == value.truncateToDouble() => value.toInt(),
    String() => int.tryParse(value.trim()),
    _ => null,
  };
}

final class NumericRule extends Rule {
  const NumericRule();
  @override
  String get name => 'numeric';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'number'};
  @override
  String? passes(ValidationContext c) =>
      asNum(c.value) == null ? 'numeric' : null;

  static num? asNum(Object? value) => switch (value) {
    num() => value,
    String() => num.tryParse(value.trim()),
    _ => null,
  };
}

final class BooleanRule extends Rule {
  const BooleanRule();
  @override
  String get name => 'boolean';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'boolean'};
  @override
  String? passes(ValidationContext c) =>
      asBool(c.value) == null ? 'boolean' : null;

  static bool? asBool(Object? value) => switch (value) {
    bool() => value,
    1 || '1' || 'true' => true,
    0 || '0' || 'false' => false,
    _ => null,
  };
}

final class ListRule extends Rule {
  const ListRule();
  @override
  String get name => 'array';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'array'};
  @override
  String? passes(ValidationContext c) =>
      c.value is List<Object?> ? null : 'array';
}

final class MapRule extends Rule {
  const MapRule();
  @override
  String get name => 'map';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'object'};
  @override
  String? passes(ValidationContext c) =>
      c.value is Map<Object?, Object?> ? null : 'map';
}

// ---------------------------------------------------------------------------
// Formats
// ---------------------------------------------------------------------------

abstract class _PatternRule extends Rule {
  const _PatternRule();
  RegExp get pattern;
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && pattern.hasMatch(value) ? null : name;
  }
}

final class EmailRule extends _PatternRule {
  const EmailRule();
  static final RegExp _email = RegExp(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
  );
  @override
  String get name => 'email';
  @override
  RegExp get pattern => _email;
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'email',
  };
}

final class UrlRule extends Rule {
  const UrlRule();

  /// Longest URL accepted.
  static const int maxLength = 8192;

  @override
  String get name => 'url';
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'uri',
  };
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    // Longer than any URL a browser or server accepts (RFC 9110 suggests
    // supporting 8000 octets); rejecting early bounds parse time (§9.3).
    if (value is! String || value.length > maxLength) {
      return 'url';
    }
    final uri = Uri.tryParse(value);
    final ok =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    return ok ? null : 'url';
  }
}

final class UuidRule extends _PatternRule {
  const UuidRule();
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  @override
  String get name => 'uuid';
  @override
  RegExp get pattern => _uuid;
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'uuid',
  };
}

final class UlidRule extends _PatternRule {
  const UlidRule();
  static final RegExp _ulid = RegExp(
    r'^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$',
  );
  @override
  String get name => 'ulid';
  @override
  RegExp get pattern => _ulid;
}

final class IpRule extends Rule {
  const IpRule({this.version});
  final int? version;
  @override
  String get name => switch (version) {
    4 => 'ipv4',
    6 => 'ipv6',
    _ => 'ip',
  };
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    final address = value is String ? InternetAddress.tryParse(value) : null;
    if (address == null) {
      return name;
    }
    final ok = switch (version) {
      4 => address.type == InternetAddressType.IPv4,
      6 => address.type == InternetAddressType.IPv6,
      _ => true,
    };
    return ok ? null : name;
  }
}

final class JsonRule extends Rule {
  const JsonRule();
  @override
  String get name => 'json';
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! String) {
      return 'json';
    }
    try {
      jsonDecode(value);
      return null;
    } on FormatException {
      return 'json';
    }
  }
}

final class AlphaRule extends _PatternRule {
  const AlphaRule();
  static final RegExp _alpha = RegExp(r'^[\p{L}\p{M}]+$', unicode: true);
  @override
  String get name => 'alpha';
  @override
  RegExp get pattern => _alpha;
}

final class AlphaNumRule extends _PatternRule {
  const AlphaNumRule();
  static final RegExp _alphaNum = RegExp(
    r'^[\p{L}\p{M}\p{N}]+$',
    unicode: true,
  );
  @override
  String get name => 'alpha_num';
  @override
  RegExp get pattern => _alphaNum;
}

final class AlphaDashRule extends _PatternRule {
  const AlphaDashRule();
  static final RegExp _alphaDash = RegExp(
    r'^[\p{L}\p{M}\p{N}_-]+$',
    unicode: true,
  );
  @override
  String get name => 'alpha_dash';
  @override
  RegExp get pattern => _alphaDash;
}

final class AsciiRule extends _PatternRule {
  const AsciiRule();
  static final RegExp _ascii = RegExp(r'^[\x00-\x7F]*$');
  @override
  String get name => 'ascii';
  @override
  RegExp get pattern => _ascii;
}

final class LowercaseRule extends Rule {
  const LowercaseRule();
  @override
  String get name => 'lowercase';
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && value == value.toLowerCase() ? null : 'lowercase';
  }
}

final class UppercaseRule extends Rule {
  const UppercaseRule();
  @override
  String get name => 'uppercase';
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && value == value.toUpperCase() ? null : 'uppercase';
  }
}

final class RegexRule extends Rule {
  const RegexRule(this.pattern, {this.negate = false});
  final RegExp pattern;
  final bool negate;
  @override
  String get name => negate ? 'not_regex' : 'regex';
  @override
  Map<String, Object?> get schemaHint =>
      negate ? const {} : {'type': 'string', 'pattern': pattern.pattern};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! String) {
      return name;
    }
    final matches = pattern.hasMatch(value);
    return matches != negate ? null : name;
  }
}

// ---------------------------------------------------------------------------
// Sizes
// ---------------------------------------------------------------------------

/// Size of a value Laravel-style: numbers by value, strings by rune count,
/// collections by length. `null` for unsupported types.
num? sizeOf(Object? value) => switch (value) {
  num() => value,
  String() => value.runes.length,
  List<Object?>() => value.length,
  Map<Object?, Object?>() => value.length,
  _ => null,
};

String _sizeKind(Object? value) => switch (value) {
  num() => 'numeric',
  List<Object?>() || Map<Object?, Object?>() => 'array',
  _ => 'string',
};

final class MinRule extends Rule {
  const MinRule(this.min);
  final num min;
  @override
  String get name => 'min';
  @override
  Map<String, Object?> get parameters => {'min': min};
  @override
  Map<String, Object?> get schemaHint => {'minimum': min, 'minLength': min};
  @override
  String? passes(ValidationContext c) {
    final size = sizeOf(c.value);
    return size != null && size >= min ? null : 'min.${_sizeKind(c.value)}';
  }
}

final class MaxRule extends Rule {
  const MaxRule(this.max);
  final num max;
  @override
  String get name => 'max';
  @override
  Map<String, Object?> get parameters => {'max': max};
  @override
  Map<String, Object?> get schemaHint => {'maximum': max, 'maxLength': max};
  @override
  String? passes(ValidationContext c) {
    final size = sizeOf(c.value);
    return size != null && size <= max ? null : 'max.${_sizeKind(c.value)}';
  }
}

final class BetweenRule extends Rule {
  const BetweenRule(this.min, this.max);
  final num min;
  final num max;
  @override
  String get name => 'between';
  @override
  Map<String, Object?> get parameters => {'min': min, 'max': max};
  @override
  String? passes(ValidationContext c) {
    final size = sizeOf(c.value);
    return size != null && size >= min && size <= max
        ? null
        : 'between.${_sizeKind(c.value)}';
  }
}

final class SizeRule extends Rule {
  const SizeRule(this.size);
  final num size;
  @override
  String get name => 'size';
  @override
  Map<String, Object?> get parameters => {'size': size};
  @override
  String? passes(ValidationContext c) =>
      sizeOf(c.value) == size ? null : 'size.${_sizeKind(c.value)}';
}

final class DigitsRule extends Rule {
  const DigitsRule(this.length);
  final int length;
  @override
  String get name => 'digits';
  @override
  Map<String, Object?> get parameters => {'digits': length};
  @override
  String? passes(ValidationContext c) {
    final text = '${c.value}';
    return RegExp(r'^\d+$').hasMatch(text) && text.length == length
        ? null
        : 'digits';
  }
}

final class DigitsBetweenRule extends Rule {
  const DigitsBetweenRule(this.min, this.max);
  final int min;
  final int max;
  @override
  String get name => 'digits_between';
  @override
  Map<String, Object?> get parameters => {'min': min, 'max': max};
  @override
  String? passes(ValidationContext c) {
    final text = '${c.value}';
    final ok =
        RegExp(r'^\d+$').hasMatch(text) &&
        text.length >= min &&
        text.length <= max;
    return ok ? null : 'digits_between';
  }
}

// ---------------------------------------------------------------------------
// Sets & comparisons
// ---------------------------------------------------------------------------

final class InRule extends Rule {
  const InRule(this.values, {this.negate = false});
  final List<Object?> values;
  final bool negate;
  @override
  String get name => negate ? 'not_in' : 'in';
  @override
  Map<String, Object?> get parameters => {'values': values.join(', ')};
  @override
  Map<String, Object?> get schemaHint => negate ? const {} : {'enum': values};
  @override
  String? passes(ValidationContext c) {
    final contained = values.any((v) => v == c.value || '$v' == '${c.value}');
    return contained != negate ? null : name;
  }
}

final class DistinctRule extends Rule {
  const DistinctRule();
  @override
  String get name => 'distinct';
  @override
  String? passes(ValidationContext c) {
    // Compare against siblings in the enclosing list.
    final lastDot = c.attribute.lastIndexOf('.');
    if (lastDot == -1) {
      return null;
    }
    final parentPath = c.attribute.substring(0, lastDot);
    final leaf = c.attribute.substring(lastDot + 1);
    final parentDot = parentPath.lastIndexOf('.');
    final listPath = parentDot == -1
        ? null
        : parentPath.substring(0, parentDot);
    final list = listPath == null ? c.root(parentPath) : c.root(listPath);
    if (list is! List<Object?>) {
      return null;
    }
    var seen = 0;
    for (final item in list) {
      final candidate = listPath == null
          ? item
          : ValidationContext.dig(item, leaf);
      if ('$candidate' == '${c.value}') {
        seen++;
      }
    }
    return seen > 1 ? 'distinct' : null;
  }
}

final class ConfirmedRule extends Rule {
  const ConfirmedRule([this.field]);
  final String? field;
  @override
  String get name => 'confirmed';
  @override
  String? passes(ValidationContext c) {
    final other = field ?? '${c.attribute}_confirmation';
    return '${c.root(other)}' == '${c.value}' ? null : 'confirmed';
  }
}

final class SameRule extends Rule {
  const SameRule(this.other, {this.negate = false});
  final String other;
  final bool negate;
  @override
  String get name => negate ? 'different' : 'same';
  @override
  Map<String, Object?> get parameters => {'other': other};
  @override
  String? passes(ValidationContext c) {
    final equal = '${c.root(other)}' == '${c.value}';
    return equal != negate ? null : name;
  }
}

final class StartsWithRule extends Rule {
  const StartsWithRule(this.prefixes);
  final List<String> prefixes;
  @override
  String get name => 'starts_with';
  @override
  Map<String, Object?> get parameters => {'values': prefixes.join(', ')};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && prefixes.any(value.startsWith) ? null : name;
  }
}

final class EndsWithRule extends Rule {
  const EndsWithRule(this.suffixes);
  final List<String> suffixes;
  @override
  String get name => 'ends_with';
  @override
  Map<String, Object?> get parameters => {'values': suffixes.join(', ')};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && suffixes.any(value.endsWith) ? null : name;
  }
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

/// Parses ISO-8601 dates/datetimes and `yyyy-MM-dd`.
DateTime? parseDate(Object? value) => switch (value) {
  DateTime() => value,
  String() => DateTime.tryParse(value.trim()),
  _ => null,
};

final class DateRule extends Rule {
  const DateRule();
  @override
  String get name => 'date';
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'date-time',
  };
  @override
  String? passes(ValidationContext c) =>
      parseDate(c.value) == null ? 'date' : null;
}

final class DateCompareRule extends Rule {
  const DateCompareRule(this.operator, this.dateOrField);
  final String operator;
  final String dateOrField;
  @override
  String get name => operator;
  @override
  Map<String, Object?> get parameters => {'date': dateOrField};
  @override
  String? passes(ValidationContext c) {
    final value = parseDate(c.value);
    final other = parseDate(dateOrField) ?? parseDate(c.root(dateOrField));
    if (value == null || other == null) {
      return operator;
    }
    final ok = switch (operator) {
      'after' => value.isAfter(other),
      'after_or_equal' => !value.isBefore(other),
      'before' => value.isBefore(other),
      'before_or_equal' => !value.isAfter(other),
      _ => false,
    };
    return ok ? null : operator;
  }
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

String _quote(String identifier) {
  if (!_identifier.hasMatch(identifier)) {
    throw ArgumentError.value(
      identifier,
      'identifier',
      'Invalid SQL identifier',
    );
  }
  return '"$identifier"';
}

String _columnFor(ValidationContext c, String? column) {
  if (column != null) {
    return column;
  }
  final dot = c.pattern.lastIndexOf('.');
  return dot == -1 ? c.pattern : c.pattern.substring(dot + 1);
}

/// `unique:table,column,ignore,idColumn` — queries the active connection
/// (joining any Zone transaction).
final class UniqueRule extends Rule {
  const UniqueRule(
    this.table, {
    this.column,
    this.ignore,
    this.idColumn = 'id',
  });
  final String table;
  final String? column;
  final Object? ignore;
  final String idColumn;
  @override
  String get name => 'unique';
  @override
  Future<String?> passes(ValidationContext c) async {
    final container = c.container;
    if (container == null) {
      throw StateError('Rule.unique requires a container (DatabaseManager).');
    }
    final db = container.make<DatabaseManager>();
    final col = _columnFor(c, column);
    final bindings = <Object?>[c.value];
    var sql =
        'SELECT COUNT(*) AS n FROM ${_quote(table)} WHERE ${_quote(col)} = ?';
    if (ignore != null) {
      sql += ' AND ${_quote(idColumn)} <> ?';
      bindings.add(ignore);
    }
    final rows = await db.select(sql, bindings);
    final count = rows.first['n'];
    return count is num && count > 0 ? 'unique' : null;
  }
}

/// `exists:table,column` — the value must be present in the table.
final class ExistsRule extends Rule {
  const ExistsRule(this.table, {this.column});
  final String table;
  final String? column;
  @override
  String get name => 'exists';
  @override
  Future<String?> passes(ValidationContext c) async {
    final container = c.container;
    if (container == null) {
      throw StateError('Rule.exists requires a container (DatabaseManager).');
    }
    final db = container.make<DatabaseManager>();
    final col = _columnFor(c, column);
    final rows = await db.select(
      'SELECT COUNT(*) AS n FROM ${_quote(table)} WHERE ${_quote(col)} = ?',
      <Object?>[c.value],
    );
    final count = rows.first['n'];
    return count is num && count > 0 ? null : 'exists';
  }
}

// ---------------------------------------------------------------------------
// Passwords & closures
// ---------------------------------------------------------------------------

final class PasswordRule extends Rule {
  const PasswordRule({
    this.min = 8,
    this.letters = false,
    this.mixedCase = false,
    this.numbers = false,
    this.symbols = false,
  });
  final int min;
  final bool letters;
  final bool mixedCase;
  final bool numbers;
  final bool symbols;
  @override
  String get name => 'password';
  @override
  Map<String, Object?> get parameters => {'min': min};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! String) {
      return 'string';
    }
    if (value.runes.length < min) {
      return 'min.string';
    }
    if (letters && !RegExp(r'\p{L}', unicode: true).hasMatch(value)) {
      return 'password.letters';
    }
    if (mixedCase &&
        !(RegExp(r'\p{Ll}', unicode: true).hasMatch(value) &&
            RegExp(r'\p{Lu}', unicode: true).hasMatch(value))) {
      return 'password.mixed';
    }
    if (numbers && !RegExp(r'\p{N}', unicode: true).hasMatch(value)) {
      return 'password.numbers';
    }
    if (symbols && !RegExp(r'[\p{P}\p{S}]', unicode: true).hasMatch(value)) {
      return 'password.symbols';
    }
    return null;
  }
}

final class ClosureRule extends Rule {
  const ClosureRule(this.check, {this.name = 'custom'});
  final FutureOr<String?> Function(ValidationContext context) check;
  @override
  final String name;
  @override
  FutureOr<String?> passes(ValidationContext c) => check(c);
}
