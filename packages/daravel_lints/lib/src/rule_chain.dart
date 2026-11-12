/// The `Rules` chain that means the same as a string rule list:
/// `'required|email|max:255'` → `Rules.required().email().max(255)`.
///
/// Mirrors `RuleParser.parseOne` of `package:daravel` rule by rule
/// (`dartisan_cli`'s `rule_chain_equivalence_test.dart` checks each one
/// against it). Returns `null` when a segment has no exact equivalent the
/// converter writes (`regex`, whose pattern may hold `|` and `,`; a rule it
/// does not know; an argument that is not a number where one is needed),
/// so a fix is offered only where it keeps the meaning.
String? ruleChainSource(String dsl) {
  final calls = <String>[];
  for (final raw in dsl.split('|')) {
    final segment = raw.trim();
    if (segment.isEmpty) {
      continue;
    }
    final call = _call(segment);
    if (call == null) {
      return null;
    }
    calls.add(call);
  }
  if (calls.isEmpty) {
    return null;
  }
  return 'Rules.${calls.join('.')}';
}

/// One segment as a call (`max(255)`), or `null`.
String? _call(String segment) {
  final colon = segment.indexOf(':');
  final name = colon == -1 ? segment : segment.substring(0, colon);
  final args = colon == -1
      ? const <String>[]
      : segment.substring(colon + 1).split(',').map((a) => a.trim()).toList();
  String s(int i) => _string(args[i]);
  String list([int from = 0]) => '[${args.skip(from).map(_string).join(', ')}]';
  String? n(int i) => _number(args[i]);
  String? integer(int i) => _integer(args[i]);
  bool has(int count) => args.length >= count;
  String? none(String method) => args.isEmpty ? '$method()' : null;
  String? one(String method) => has(1) ? '$method(${s(0)})' : null;
  String? all(String method) => has(1) ? '$method(${list()})' : null;
  String? firstAndRest(String method) =>
      has(2) ? '$method(${s(0)}, ${list(1)})' : null;
  String? numeric(String method, int count) {
    if (!has(count)) {
      return null;
    }
    final values = [for (var i = 0; i < count; i++) n(i)];
    return values.contains(null) ? null : '$method(${values.join(', ')})';
  }

  String? integers(String method, int count) {
    if (!has(count)) {
      return null;
    }
    final values = [for (var i = 0; i < count; i++) integer(i)];
    return values.contains(null) ? null : '$method(${values.join(', ')})';
  }

  return switch (name) {
    'required' => none('required'),
    'nullable' => none('nullable'),
    'sometimes' => none('sometimes'),
    'bail' => none('bail'),
    'present' => none('present'),
    'filled' => none('filled'),
    'prohibited' => none('prohibited'),
    'accepted' => none('accepted'),
    'declined' => none('declined'),
    'missing' => none('missing'),
    'hex_color' => none('hexColor'),
    'mac_address' => none('macAddress'),
    'base64' => none('base64'),
    'exclude' => none('exclude'),
    'string' => none('string'),
    'integer' || 'int' => none('integer'),
    'numeric' => none('numeric'),
    'boolean' || 'bool' => none('boolean'),
    'list' => none('list'),
    'map' || 'object' => none('map'),
    'email' => none('email'),
    'url' => none('url'),
    'file' => none('file'),
    'uuid' => none('uuid'),
    'ulid' => none('ulid'),
    'ip' => none('ip'),
    'ipv4' => none('ipv4'),
    'ipv6' => none('ipv6'),
    'json' => none('json'),
    'alpha' => none('alpha'),
    'alpha_num' => none('alphaNum'),
    'alpha_dash' => none('alphaDash'),
    'ascii' => none('ascii'),
    'lowercase' => none('lowercase'),
    'uppercase' => none('uppercase'),
    'distinct' when args.every((a) => a == 'strict' || a == 'ignore_case') =>
      'distinct(${[if (args.contains('strict')) 'strict: true', if (args.contains('ignore_case')) 'ignoreCase: true'].join(', ')})',
    'date' => none('date'),
    'required_if' when args.length == 2 => 'requiredIf(${s(0)}, ${s(1)})',
    'required_unless' when args.length == 2 =>
      'requiredUnless(${s(0)}, ${s(1)})',
    'accepted_if' => firstAndRest('acceptedIf'),
    'declined_if' => firstAndRest('declinedIf'),
    'required_with' => all('requiredWith'),
    'required_with_all' => all('requiredWithAll'),
    'required_without' => all('requiredWithout'),
    'required_without_all' => all('requiredWithoutAll'),
    'required_if_accepted' => one('requiredIfAccepted'),
    'required_if_declined' => one('requiredIfDeclined'),
    'present_if' => firstAndRest('presentIf'),
    'present_unless' => firstAndRest('presentUnless'),
    'present_with' => all('presentWith'),
    'present_with_all' => all('presentWithAll'),
    'prohibited_if' => firstAndRest('prohibitedIf'),
    'prohibited_unless' => firstAndRest('prohibitedUnless'),
    'prohibited_if_accepted' => one('prohibitedIfAccepted'),
    'prohibited_if_declined' => one('prohibitedIfDeclined'),
    'prohibits' => all('prohibits'),
    'missing_if' => firstAndRest('missingIf'),
    'missing_unless' => firstAndRest('missingUnless'),
    'missing_with' => all('missingWith'),
    'missing_with_all' => all('missingWithAll'),
    'required_array_keys' => all('requiredArrayKeys'),
    'contains' => all('contains'),
    'doesnt_contain' => all('doesntContain'),
    'doesnt_start_with' => all('doesntStartWith'),
    'doesnt_end_with' => all('doesntEndWith'),
    'starts_with' => all('startsWith'),
    'ends_with' => all('endsWith'),
    'in_array' => one('inArray'),
    'in_array_keys' => all('inArrayKeys'),
    'array_keys' => all('arrayKeys'),
    'encoding' => one('encoding'),
    'exclude_if' => firstAndRest('excludeIf'),
    'exclude_unless' => firstAndRest('excludeUnless'),
    'exclude_with' => one('excludeWith'),
    'exclude_without' => one('excludeWithout'),
    // A field name or a number: RuleParser passes the text either way.
    'gt' => one('gt'),
    'gte' => one('gte'),
    'lt' => one('lt'),
    'lte' => one('lte'),
    'multiple_of' => one('multipleOf'),
    'date_equals' => one('dateEquals'),
    'same' => one('same'),
    'different' => one('different'),
    'after' => one('after'),
    'after_or_equal' => one('afterOrEqual'),
    'before' => one('before'),
    'before_or_equal' => one('beforeOrEqual'),
    'decimal' when args.length == 1 => integers('decimal', 1),
    'decimal' when args.length == 2 => integers('decimal', 2),
    'min_digits' => integers('minDigits', 1),
    'max_digits' => integers('maxDigits', 1),
    'digits' => integers('digits', 1),
    'digits_between' => integers('digitsBetween', 2),
    'min' => numeric('min', 1),
    'max' => numeric('max', 1),
    'size' => numeric('size', 1),
    'between' => numeric('between', 2),
    'timezone' when args.isEmpty => 'timezone()',
    'timezone' when args.length == 1 => 'timezone(${s(0)})',
    'array' => args.isEmpty ? 'array()' : 'array(${list()})',
    'image' when args.every((a) => a == 'allow_svg') =>
      args.isEmpty ? 'image()' : 'image(allowSvg: true)',
    'mimes' =>
      has(1)
          ? 'mimes([${args.map((a) => _string(a.toLowerCase())).join(', ')}])'
          : null,
    'extensions' =>
      has(1)
          ? 'extensions([${args.map((a) => _string(a.toLowerCase())).join(', ')}])'
          : null,
    'mimetypes' => all('mimetypes'),
    'in' => all('inList'),
    'not_in' => all('notIn'),
    'confirmed' when args.length <= 1 =>
      args.isEmpty ? 'confirmed()' : 'confirmed(${s(0)})',
    'date_format' => all('dateFormat'),
    'unique' when has(1) && args.length <= 4 => _unique(args),
    'exists' when args.length == 1 => 'exists(${s(0)})',
    'exists' when args.length == 2 => 'exists(${s(0)}, ${s(1)})',
    'password' when args.isEmpty => 'password()',
    'password' when args.length == 1 && integer(0) != null =>
      'password(min: ${integer(0)})',
    _ => null,
  };
}

/// `unique:table,column,ignore,idColumn`, with `NULL` for a skipped value,
/// as `RuleParser` reads it.
String _unique(List<String> args) {
  String? at(int i) => args.length > i && args[i] != 'NULL' ? args[i] : null;
  final column = at(1);
  final ignore = at(2);
  final idColumn = args.length > 3 ? args[3] : 'id';
  final values = [
    _string(args[0]),
    if (column != null || ignore != null || idColumn != 'id')
      column == null ? 'null' : _string(column),
    if (ignore != null || idColumn != 'id')
      ignore == null ? 'null' : _string(ignore),
    if (idColumn != 'id') _string(idColumn),
  ];
  return 'unique(${values.join(', ')})';
}

/// The number `RuleParser` reads from [value] (`num.parse`), written as a
/// Dart literal: `+5` and `1e3` parse but are not the literal to write
/// (`+5` does not compile), so the parsed value is written (`5`,
/// `1000.0`). `null` when it does not parse or has no literal
/// (`Infinity`, `NaN`).
String? _number(String value) {
  final number = num.tryParse(value);
  return number == null || (number is double && !number.isFinite)
      ? null
      : '$number';
}

/// The integer `RuleParser` reads from [value] (`int.parse`), as a Dart
/// literal (`+5` → `5`, `0x10` → `16`); `null` when it does not parse.
String? _integer(String value) => int.tryParse(value)?.toString();

/// [value] as a single-quoted Dart string literal.
String _string(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}
