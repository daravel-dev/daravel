import 'rule.dart';
import 'rules.dart';

/// Parses Laravel's string rule DSL (`'required|email|max:255'`) into
/// [Rule] objects (ADR-020). Parsing happens once at definition time and
/// unknown rules throw immediately, so typos surface at boot or in tests,
/// never in a request.
abstract final class RuleParser {
  /// Parses a rule map whose values are DSL strings, `List<Rule>` or mixed
  /// lists of rules and DSL strings.
  static Map<String, List<Rule>> parseMap(Map<String, Object> rules) => {
    for (final entry in rules.entries) entry.key: parseValue(entry.value),
  };

  /// Parses a single value (`String` DSL, `Rule` or `List<Object>`).
  static List<Rule> parseValue(Object value) => switch (value) {
    String() => parse(value),
    Rule() => [value],
    List<Object?>() => [
      for (final item in value)
        ...switch (item) {
          String() => parse(item),
          Rule() => [item],
          _ => throw ArgumentError.value(
            item,
            'rules',
            'Expected a Rule or DSL string',
          ),
        },
    ],
    _ => throw ArgumentError.value(
      value,
      'rules',
      'Expected a String, Rule or List',
    ),
  };

  /// Parses `'required|email|max:255|in:a,b'`.
  static List<Rule> parse(String dsl) => [
    for (final part in dsl.split('|'))
      if (part.trim().isNotEmpty) parseOne(part.trim()),
  ];

  /// Parses one `name[:arg,arg]` segment.
  static Rule parseOne(String segment) {
    final colon = segment.indexOf(':');
    final name = colon == -1 ? segment : segment.substring(0, colon);
    final args = colon == -1
        ? const <String>[]
        : segment.substring(colon + 1).split(',').map((a) => a.trim()).toList();
    num number(int i) => num.parse(args[i]);
    int integer(int i) => int.parse(args[i]);
    return switch (name) {
      'required' => Rules.required(),
      'nullable' => Rules.nullable(),
      'sometimes' => Rules.sometimes(),
      'bail' => Rules.bail(),
      'present' => Rules.present(),
      'filled' => Rules.filled(),
      'prohibited' => Rules.prohibited(),
      'required_if' => Rules.requiredIf(args[0], args[1]),
      'required_unless' => Rules.requiredUnless(args[0], args[1]),
      'required_with' => Rules.requiredWith(args),
      'required_without' => Rules.requiredWithout(args),
      'string' => Rules.string(),
      'integer' || 'int' => Rules.integer(),
      'numeric' => Rules.numeric(),
      'boolean' || 'bool' => Rules.boolean(),
      'array' || 'list' => Rules.list(),
      'map' || 'object' => Rules.map(),
      'email' => Rules.email(),
      'url' => Rules.url(),
      'uuid' => Rules.uuid(),
      'ulid' => Rules.ulid(),
      'ip' => Rules.ip(),
      'ipv4' => Rules.ipv4(),
      'ipv6' => Rules.ipv6(),
      'json' => Rules.json(),
      'alpha' => Rules.alpha(),
      'alpha_num' => Rules.alphaNum(),
      'alpha_dash' => Rules.alphaDash(),
      'ascii' => Rules.ascii(),
      'lowercase' => Rules.lowercase(),
      'uppercase' => Rules.uppercase(),
      'regex' => Rules.regex(_regexFrom(segment)),
      'not_regex' => Rules.notRegex(_regexFrom(segment)),
      'min' => Rules.min(number(0)),
      'max' => Rules.max(number(0)),
      'between' => Rules.between(number(0), number(1)),
      'size' => Rules.size(number(0)),
      'digits' => Rules.digits(integer(0)),
      'digits_between' => Rules.digitsBetween(integer(0), integer(1)),
      'in' => Rules.inList(args),
      'not_in' => Rules.notIn(args),
      'distinct' => Rules.distinct(),
      'confirmed' => Rules.confirmed(args.isEmpty ? null : args[0]),
      'same' => Rules.same(args[0]),
      'different' => Rules.different(args[0]),
      'starts_with' => Rules.startsWith(args),
      'ends_with' => Rules.endsWith(args),
      'date' => Rules.date(),
      'after' => Rules.after(args[0]),
      'after_or_equal' => Rules.afterOrEqual(args[0]),
      'before' => Rules.before(args[0]),
      'before_or_equal' => Rules.beforeOrEqual(args[0]),
      'unique' => Rules.unique(
        args[0],
        args.length > 1 && args[1] != 'NULL' ? args[1] : null,
        args.length > 2 && args[2] != 'NULL' ? args[2] : null,
        args.length > 3 ? args[3] : 'id',
      ),
      'exists' => Rules.exists(args[0], args.length > 1 ? args[1] : null),
      'password' => Rules.password(min: args.isEmpty ? 8 : integer(0)),
      _ => throw ArgumentError.value(
        segment,
        'rule',
        'Unknown validation rule "$name"',
      ),
    };
  }

  /// `regex:/^[a-z]+$/i` → [RegExp] (delimiters stripped; the `i`, `m`,
  /// `s` and `u` flags map to the matching [RegExp] options because Dart has
  /// no inline `(?i)` syntax).
  static RegExp _regexFrom(String segment) {
    var body = segment.substring(segment.indexOf(':') + 1);
    var flags = '';
    if (body.length >= 2 && body.startsWith('/')) {
      final end = body.lastIndexOf('/');
      flags = body.substring(end + 1);
      body = body.substring(1, end);
    }
    return RegExp(
      body,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u'),
    );
  }
}
