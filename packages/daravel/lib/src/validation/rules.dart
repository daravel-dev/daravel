import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../database/database_manager.dart';
import '../database/orm/model.dart';
import '../database/orm/model_definition.dart';
import '../database/query/query_builder.dart';
import '../foundation/clock.dart';
import '../http/uploaded_file.dart';
import 'dns.dart';
import 'object_rules.dart';
import 'php_date_format.dart';
import 'php_email_filter.dart';
import 'rule.dart';
import 'typed_rules.dart';

/// Factory facade for built-in rules (`Rule.required()`, `Rule.email()`...).
/// Each factory returns a `const`-friendly [Rule] subclass that can be
/// introspected for messages and OpenAPI hints.
abstract final class Rules {
  /// `gt:field` or `gt:value`: greater than another field (same type) or a number.
  static Rule gt(Object target) => CompareRule('gt', '$target');

  /// `gte`: greater than or equal to another field or a number.
  static Rule gte(Object target) => CompareRule('gte', '$target');

  /// `lt`: less than another field or a number.
  static Rule lt(Object target) => CompareRule('lt', '$target');

  /// `lte`: less than or equal to another field or a number.
  static Rule lte(Object target) => CompareRule('lte', '$target');

  /// `decimal:min,max`: a number with [min] to [max] digits after the point
  /// (exactly [min] without [max]).
  static Rule decimal(int min, [int? max]) => DecimalRule(min, max);

  /// `multiple_of`: a multiple of [factor].
  static Rule multipleOf(Object factor) => MultipleOfRule(factor);

  /// `min_digits`: an integer of at least [digits] digits.
  static Rule minDigits(int digits) => DigitCountRule('min_digits', digits);

  /// `max_digits`: an integer of at most [digits] digits.
  static Rule maxDigits(int digits) => DigitCountRule('max_digits', digits);

  /// `date_equals`: the same day as a date or another field.
  static Rule dateEquals(String dateOrField) =>
      DateCompareRule('date_equals', dateOrField);

  /// `timezone`: a time zone identifier of [group] (`all` by default).
  static Rule timezone([String group = 'all']) => TimezoneRule(group);

  /// `required_with_all`: required when all of [others] are present.
  static Rule requiredWithAll(List<String> others) =>
      RequiredWithAllRule(others);

  /// `required_without_all`: required when none of [others] is present.
  static Rule requiredWithoutAll(List<String> others) =>
      RequiredWithoutAllRule(others);

  /// `required_if_accepted`: required when [other] is accepted.
  static Rule requiredIfAccepted(String other) => RequiredIfAcceptedRule(other);

  /// `present_if`: present when [other] is one of [values].
  static Rule presentIf(String other, List<String> values) =>
      DependentRule('present_if', other, values);

  /// `prohibited_if`: must be empty or absent when [other] is one of [values].
  static Rule prohibitedIf(String other, List<String> values) =>
      DependentRule('prohibited_if', other, values);

  /// `prohibited_unless`: must be empty or absent unless [other] is one of
  /// [values].
  static Rule prohibitedUnless(String other, List<String> values) =>
      DependentRule('prohibited_unless', other, values);

  /// `prohibits`: when present, every one of [others] must be absent.
  static Rule prohibits(List<String> others) => ProhibitsRule(others);

  /// `missing`: the key must not be in the input at all.
  static Rule missing() => const MissingRule();

  /// `missing_if`: missing when [other] is one of [values].
  static Rule missingIf(String other, List<String> values) =>
      DependentRule('missing_if', other, values);

  /// `missing_unless`: missing unless [other] is one of [values].
  static Rule missingUnless(String other, List<String> values) =>
      DependentRule('missing_unless', other, values);

  /// `missing_with`: missing when any of [others] is present.
  static Rule missingWith(List<String> others) =>
      PresenceWithRule('missing_with', others);

  /// `missing_with_all`: missing when all of [others] are present.
  static Rule missingWithAll(List<String> others) =>
      PresenceWithRule('missing_with_all', others);

  /// `present_unless`: present unless [other] is one of [values].
  static Rule presentUnless(String other, List<String> values) =>
      DependentRule('present_unless', other, values);

  /// `present_with`: present when any of [others] is present.
  static Rule presentWith(List<String> others) =>
      PresenceWithRule('present_with', others);

  /// `present_with_all`: present when all of [others] are present.
  static Rule presentWithAll(List<String> others) =>
      PresenceWithRule('present_with_all', others);

  /// `prohibited_if_accepted`: must be empty or absent when [other] is
  /// accepted.
  static Rule prohibitedIfAccepted(String other) =>
      AcceptanceConditionRule('prohibited_if_accepted', other);

  /// `prohibited_if_declined`: must be empty or absent when [other] is
  /// declined.
  static Rule prohibitedIfDeclined(String other) =>
      AcceptanceConditionRule('prohibited_if_declined', other);

  /// `required_if_declined`: required when [other] is declined.
  static Rule requiredIfDeclined(String other) =>
      AcceptanceConditionRule('required_if_declined', other);

  /// `required_array_keys`: an array (JSON object or list) with every one
  /// of [keys].
  static Rule requiredArrayKeys(List<String> keys) =>
      RequiredArrayKeysRule(keys);

  /// `contains`: an array holding every one of [values] (compared loosely,
  /// as PHP's `in_array`).
  static Rule contains(List<String> values) =>
      ArrayValuesRule('contains', values);

  /// `doesnt_contain`: an array holding none of [values] (compared
  /// strictly).
  static Rule doesntContain(List<String> values) =>
      ArrayValuesRule('doesnt_contain', values);

  /// `doesnt_start_with`: text that starts with none of [prefixes].
  static Rule doesntStartWith(List<String> prefixes) =>
      DoesntAffixRule('doesnt_start_with', prefixes);

  /// `doesnt_end_with`: text that ends with none of [suffixes].
  static Rule doesntEndWith(List<String> suffixes) =>
      DoesntAffixRule('doesnt_end_with', suffixes);

  /// `in_array`: one of the values at [other], a path with `*`
  /// (`in_array:items.*.id`), compared strictly.
  static Rule inArray(String other) => InArrayRule(other);

  /// `in_array_keys`: an array with at least one of [keys].
  static Rule inArrayKeys(List<String> keys) =>
      ArrayKeysRule('in_array_keys', keys);

  /// `array_keys`: an array with no key but [keys] (Laravel 13).
  static Rule arrayKeys(List<String> keys) => ArrayKeysRule('array_keys', keys);

  /// `hex_color`: `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
  static Rule hexColor() => const HexColorRule();

  /// `mac_address`: six hex pairs joined by `:` or `-`, or three hex
  /// quads joined by `.` (PHP's `FILTER_VALIDATE_MAC`).
  static Rule macAddress() => const MacAddressRule();

  /// `encoding:UTF-8`: text (or an uploaded file's bytes) valid in
  /// [encoding]: `UTF-8`, `ASCII` or `ISO-8859-1`; any other name is an
  /// [ArgumentError], as Laravel throws for an unknown one.
  static Rule encoding(String encoding) => EncodingRule(encoding);

  /// `base64`: text that decodes as standard Base64 and encodes back to the
  /// same text (Laravel 13).
  static Rule base64() => const Base64Rule();

  /// `exclude`: leaves the field out of the validated data.
  static Rule exclude() => const ExcludeRule('exclude');

  /// `exclude_if`: leaves the field out when [other] is one of [values].
  static Rule excludeIf(String other, List<String> values) =>
      ExcludeRule('exclude_if', other: other, values: values);

  /// `exclude_unless`: leaves the field out unless [other] is one of [values].
  static Rule excludeUnless(String other, List<String> values) =>
      ExcludeRule('exclude_unless', other: other, values: values);

  /// `exclude_with`: leaves the field out when [other] is present.
  static Rule excludeWith(String other) =>
      ExcludeRule('exclude_with', other: other);

  /// `exclude_without`: leaves the field out when [other] is absent.
  static Rule excludeWithout(String other) =>
      ExcludeRule('exclude_without', other: other);

  /// `Rule::enum()`: the value is the enum's name, or [toValue] of it.
  static EnumRule<E> enum_<E extends Enum>(
    List<E> values, {
    Object? Function(E value)? toValue,
    List<E>? only,
    List<E>? except,
  }) => EnumRule<E>(values, toValue: toValue, only: only, except: except);

  /// `required`: present and not empty (not null, `''`, `[]` or `{}`).
  static Rule required() => const RequiredRule();

  /// `nullable`: null passes, and the field's other rules are skipped.
  static Rule nullable() => const NullableRule();

  /// `sometimes`: validate only when the field is present.
  static Rule sometimes() => const SometimesRule();

  /// `bail`: stop at the field's first failing rule.
  static Rule bail() => const BailRule();

  /// `present`: the key must exist, even empty.
  static Rule present() => const PresentRule();

  /// `filled`: not empty when present.
  static Rule filled() => const FilledRule();

  /// `prohibited`: must be empty or absent.
  static Rule prohibited() => const ProhibitedRule();

  /// `required_if:other,value`: required when [other] is [value], compared
  /// as Laravel compares them (`'true'` matches a boolean input, `'null'`
  /// a null one, `'5'` the number 5). A missing [other] never requires it.
  static Rule requiredIf(String other, Object? value) =>
      RequiredIfRule(other, value);

  /// `required_if:role,admin,owner`: required when [other] is one of
  /// [values].
  static Rule requiredIfIn(String other, List<Object?> values) =>
      RequiredIfRule.oneOf(other, _atLeastOne('required_if', values));

  /// `required_unless:other,value`: required unless [other] is [value].
  static Rule requiredUnless(String other, Object? value) =>
      RequiredUnlessRule(other, value);

  /// `required_unless:role,guest,bot`: required unless [other] is one of
  /// [values].
  static Rule requiredUnlessIn(String other, List<Object?> values) =>
      RequiredUnlessRule.oneOf(other, _atLeastOne('required_unless', values));

  /// `accepted`: `yes`, `on`, `1`, `true` (checkboxes, terms).
  static Rule accepted() => const AcceptanceRule('accepted', _isAccepted);

  /// `accepted_if`: accepted when [other] is one of [values].
  static Rule acceptedIf(String other, List<String> values) =>
      AcceptanceRule('accepted_if', _isAccepted, other: other, values: values);

  /// `declined`: `no`, `off`, `0`, `false`.
  static Rule declined() => const AcceptanceRule('declined', _isDeclined);

  /// `declined_if`: declined when [other] is one of [values].
  static Rule declinedIf(String other, List<String> values) =>
      AcceptanceRule('declined_if', _isDeclined, other: other, values: values);

  /// `required_with`: required when any of [others] is present.
  static Rule requiredWith(List<String> others) => RequiredWithRule(others);

  /// `required_without`: required when any of [others] is absent.
  static Rule requiredWithout(List<String> others) =>
      RequiredWithoutRule(others);

  /// `string`: a string.
  static Rule string() => const StringRule();

  /// `integer`: an integer, or a string of one.
  static Rule integer() => const IntegerRule();

  /// `numeric`: a number, or a string of one.
  static Rule numeric() => const NumericRule();

  /// `boolean`: `true`, `false`, `1`, `0`, `'1'` or `'0'`.
  static Rule boolean() => const BooleanRule();

  /// `array`: a JSON array or a JSON object, as Laravel's `array` accepts
  /// any PHP array. With [keys] (`array:name,email`), every key of the
  /// value must be one of them; a list's keys are its indexes (`'0'`,
  /// `'1'`, ...), as in PHP.
  static Rule array([List<String>? keys]) => ArrayRule(keys);

  /// `list`: a JSON array, as Laravel's `list` (an array whose keys are
  /// `0..n-1`). A JSON object fails.
  static Rule list() => const ListRule();

  /// `map` (Daravel): a JSON object. A JSON array fails.
  static Rule map() => const MapRule();

  /// `email`, or `email:rfc,dns,...` with the modes set: every mode given
  /// must pass, `rfc` when none is. [dns] looks the domain up as egulias'
  /// `DNSCheckValidation` (through the container's [DnsResolver]); it is
  /// checked last and, as in Laravel, alone it does not check the syntax
  /// (`email:rfc,dns` does both). [spoof] needs ICU: it throws
  /// [UnsupportedError] here, when the rule is built. [rfc] and [strict]
  /// are, for now, the same HTML-style check, stricter than egulias' RFC
  /// parser.
  static Rule email({
    bool rfc = false,
    bool strict = false,
    bool dns = false,
    bool spoof = false,
    bool filter = false,
    bool filterUnicode = false,
  }) => EmailRule.checked({
    if (rfc) 'rfc',
    if (strict) 'strict',
    if (dns) 'dns',
    if (spoof) 'spoof',
    if (filter) 'filter',
    if (filterUnicode) 'filter_unicode',
  });

  /// `active_url`: a URL whose host has an A or AAAA record (one lookup
  /// through the container's [DnsResolver]; an IP address fails, as in
  /// Laravel).
  static Rule activeUrl() => const ActiveUrlRule();

  /// `url`: an absolute URL with a scheme and host.
  static Rule url() => const UrlRule();

  /// `file`: an uploaded file.
  static Rule file() => const FileRule();

  /// `image`: an uploaded jpg, jpeg, png, bmp, gif or webp; svg only when
  /// [allowSvg].
  static Rule image({bool allowSvg = false}) => ImageRule(allowSvg: allowSvg);

  /// `mimes`: an uploaded file whose content matches one of [extensions].
  static Rule mimes(List<String> extensions) => MimesRule(extensions);

  /// `mimetypes`: an uploaded file of one of the MIME [types].
  static Rule mimetypes(List<String> types) => MimetypesRule(types);

  /// `extensions`: an uploaded file whose name ends with one of [extensions].
  static Rule extensions(List<String> extensions) => ExtensionsRule(extensions);

  /// `uuid`: a UUID.
  static Rule uuid() => const UuidRule();

  /// `ulid`: a ULID.
  static Rule ulid() => const UlidRule();

  /// `ip`: an IPv4 or IPv6 address.
  static Rule ip() => const IpRule();

  /// `ipv4`: an IPv4 address.
  static Rule ipv4() => const IpRule(version: 4);

  /// `ipv6`: an IPv6 address.
  static Rule ipv6() => const IpRule(version: 6);

  /// `json`: a string holding valid JSON.
  static Rule json() => const JsonRule();

  /// `alpha`: Unicode letters only.
  static Rule alpha() => const AlphaRule();

  /// `alpha_num`: Unicode letters and digits only.
  static Rule alphaNum() => const AlphaNumRule();

  /// `alpha_dash`: letters, digits, `-` and `_` only.
  static Rule alphaDash() => const AlphaDashRule();

  /// `ascii`: 7-bit ASCII characters only.
  static Rule ascii() => const AsciiRule();

  /// `lowercase`: no upper case letters.
  static Rule lowercase() => const LowercaseRule();

  /// `uppercase`: no lower case letters.
  static Rule uppercase() => const UppercaseRule();

  /// `regex`: matches [pattern].
  static Rule regex(RegExp pattern) => RegexRule(pattern);

  /// `not_regex`: does not match [pattern].
  static Rule notRegex(RegExp pattern) => RegexRule(pattern, negate: true);

  /// `min`: at least [value]: the number, the string's length, the list's
  /// size, or the file's kilobytes.
  static Rule min(num value) => MinRule(value);

  /// `max`: at most [value], measured as [min].
  static Rule max(num value) => MaxRule(value);

  /// `between`: from [min] to [max], measured as [Rules.min].
  static Rule between(num min, num max) => BetweenRule(min, max);

  /// `size`: exactly [value], measured as [min].
  static Rule size(num value) => SizeRule(value);

  /// `digits`: an integer of exactly [length] digits.
  static Rule digits(int length) => DigitsRule(length);

  /// `digits_between`: an integer of [min] to [max] digits.
  static Rule digitsBetween(int min, int max) => DigitsBetweenRule(min, max);

  /// `in`: one of [values].
  static Rule inList(List<Object?> values) => InRule(values);

  /// `not_in`: none of [values].
  static Rule notIn(List<Object?> values) => InRule(values, negate: true);

  /// `Rule::enum`: the name (or value) of one of the enum's [values].
  static Rule enumValues<E extends Enum>(List<E> values) =>
      InRule(values.map((v) => v.name).toList());

  /// `distinct`: no duplicates among the list's items (`items.*`).
  static Rule distinct() => const DistinctRule();

  /// `confirmed`: equals `<field>_confirmation`, or [field] when given.
  static Rule confirmed([String? field]) => ConfirmedRule(field);

  /// `same`: equals [other].
  static Rule same(String other) => SameRule(other);

  /// `different`: differs from [other].
  static Rule different(String other) => SameRule(other, negate: true);

  /// `starts_with`: starts with one of [prefixes].
  static Rule startsWith(List<String> prefixes) => StartsWithRule(prefixes);

  /// `ends_with`: ends with one of [suffixes].
  static Rule endsWith(List<String> suffixes) => EndsWithRule(suffixes);

  /// `date`: a date `DateTime.tryParse` accepts.
  static Rule date() => const DateRule();

  /// Laravel's `date_format:Y-m-d` (several formats: any of them).
  static Rule dateFormat(List<String> formats) => DateFormatRule(formats);

  /// `after`: after a date (`'2026-01-01'`, `'today'`) or another field.
  static Rule after(String dateOrField) =>
      DateCompareRule('after', dateOrField);

  /// `after_or_equal`: on or after a date or another field.
  static Rule afterOrEqual(String dateOrField) =>
      DateCompareRule('after_or_equal', dateOrField);

  /// `before`: before a date or another field.
  static Rule before(String dateOrField) =>
      DateCompareRule('before', dateOrField);

  /// `before_or_equal`: on or before a date or another field.
  static Rule beforeOrEqual(String dateOrField) =>
      DateCompareRule('before_or_equal', dateOrField);

  /// `unique:table,column`: no row of [table] has the value in [column]
  /// (the field name when null); [ignore] skips the row with that
  /// [idColumn], for updates.
  static UniqueRule unique(
    String table, [
    String? column,
    Object? ignore,
    String idColumn = 'id',
  ]) => UniqueRule(table, column: column, ignore: ignore, idColumn: idColumn);

  /// `exists:table,column`: a row of [table] has the value in [column].
  static ExistsRule exists(String table, [String? column]) =>
      ExistsRule(table, column: column);

  /// `Password::min(8)` and its rules: at least [min] characters, and
  /// letters, mixed case, numbers or symbols when asked.
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

  /// The rules that read [definition]'s table, typed by its columns:
  /// `Rules.of(User.definition).unique(User.cols.email)`.
  static ModelRules<M> of<M extends Model>(ModelDefinition<M> definition) =>
      ModelRules<M>(definition);

  /// A rule of your own: [check] returns an error message, or null when the
  /// value passes; [name] keys its translations.
  static Rule custom(
    FutureOr<String?> Function(ValidationContext context) check, {
    String name = 'custom',
  }) => ClosureRule(check, name: name);

  /// `Rule::when($condition, $rules, $defaultRules)`: [rules] when
  /// [condition] is true, [otherwise] when it is false. For a condition on
  /// the input, use [whenInput].
  static Rule when(
    bool condition,
    List<Rule> rules, {
    List<Rule> otherwise = const [],
  }) => ConditionalRule('when', (_) => condition, rules, otherwise);

  /// `Rule::when(fn ($input) => ..., $rules, $defaultRules)`: [rules] when
  /// [condition] holds for the whole input, [otherwise] when it does not.
  /// Decided once per validation, before any rule runs, on the input after
  /// `FormRequest.prepare` (Laravel's `filterConditionalRules`).
  static Rule whenInput(
    bool Function(Map<String, Object?> input) condition,
    List<Rule> rules, {
    List<Rule> otherwise = const [],
  }) => ConditionalRule('when', condition, rules, otherwise);

  /// `Rule::unless($condition, $rules, $defaultRules)`: [rules] when
  /// [condition] is false, [otherwise] when it is true.
  static Rule unless(
    bool condition,
    List<Rule> rules, {
    List<Rule> otherwise = const [],
  }) => ConditionalRule('unless', (_) => !condition, rules, otherwise);

  /// `Rule::unless(fn ($input) => ..., $rules, $defaultRules)`: [whenInput]
  /// with the condition inverted.
  static Rule unlessInput(
    bool Function(Map<String, Object?> input) condition,
    List<Rule> rules, {
    List<Rule> otherwise = const [],
  }) =>
      ConditionalRule('unless', (input) => !condition(input), rules, otherwise);

  /// `Rule::forEach(fn ($value, $attribute) => [...])`: rules for each
  /// element of an array attribute (`'items.*.id': Rules.forEach(...)`),
  /// built from the element's value, attribute, parent and the input.
  static Rule forEach(List<Rule> Function(ForEachItem item) rules) =>
      ForEachRule.own(rules);

  /// `Rule::forEach` returning keyed rules: rules for keys of each element
  /// (`{'meta': [...]}` validates `items.2.meta`); those attributes are part
  /// of the validated data, as in Laravel.
  static Rule forEachNested(
    Map<String, List<Rule>> Function(ForEachItem item) rules,
  ) => ForEachRule.nested(rules);

  /// `Rule::anyOf([...])`: the value passes when it passes one of
  /// [alternatives]. Each is validated on the value alone, as Laravel does:
  /// a rule naming another field does not see the rest of the input.
  static Rule anyOf(List<List<Rule>> alternatives) => AnyOfRule(alternatives);

  /// `Rule::anyOf` with keyed alternatives: a map value passes when its keys
  /// pass one of [alternatives] (`[{'type': [...], 'id': [...]}, ...]`).
  static Rule anyOfKeyed(List<Map<String, List<Rule>>> alternatives) =>
      AnyOfRule.keyed(alternatives);
}

// ---------------------------------------------------------------------------
// Presence
// ---------------------------------------------------------------------------

/// `required`: see [Rules.required].
final class RequiredRule extends Rule {
  /// The required rule; use [Rules.required].
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

/// `present`: see [Rules.present].
final class PresentRule extends Rule {
  /// The present rule; use [Rules.present].
  const PresentRule();
  @override
  String get name => 'present';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) => c.present ? null : 'present';
}

/// `filled`: see [Rules.filled].
final class FilledRule extends Rule {
  /// The filled rule; use [Rules.filled].
  const FilledRule();
  @override
  String get name => 'filled';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) =>
      c.present && isEmptyValue(c.value) ? 'filled' : null;
}

/// `prohibited`: see [Rules.prohibited].
final class ProhibitedRule extends Rule {
  /// The prohibited rule; use [Rules.prohibited].
  const ProhibitedRule();
  @override
  String get name => 'prohibited';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) =>
      c.present && !isEmptyValue(c.value) ? 'prohibited' : null;
}

/// `required_if`: see [Rules.requiredIf] and [Rules.requiredIfIn].
final class RequiredIfRule extends Rule {
  /// Required when [other] is [expected].
  const RequiredIfRule(this.other, Object? expected)
    : _one = expected,
      _many = null;

  /// Required when [other] is one of [values]
  /// (`required_if:role,admin,owner`); use [Rules.requiredIfIn].
  const RequiredIfRule.oneOf(this.other, List<Object?> values)
    : _one = null,
      _many = values;

  final Object? _one;
  final List<Object?>? _many;

  /// The field compared.
  final String other;

  /// The values that make this field required, as written in the rule
  /// (`true`, `null`, `5`), compared as Laravel compares them.
  List<String> get values => [
    for (final value in _many ?? [_one]) '$value',
  ];

  /// The first of [values].
  Object? get expected => _many == null ? _one : _many.first;

  @override
  String get name => 'required_if';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {
    'other': other,
    'value': values.first,
  };

  // Laravel's replaceRequiredIf is replaceAcceptedIf: `:value` is the
  // other field's input.
  @override
  Map<String, Object?> parametersFor(ValidationContext context) =>
      _otherParameters(context, other);

  @override
  String? passes(ValidationContext c) {
    // 13.x ValidatesAttributes::validateRequiredIf (2189-2204): a missing
    // other field never requires this one.
    if (!c.has(other)) {
      return null;
    }
    return _dependentMatches(c, other, values) && isEmptyValue(c.value)
        ? 'required_if'
        : null;
  }
}

/// `required_unless`: see [Rules.requiredUnless] and
/// [Rules.requiredUnlessIn].
final class RequiredUnlessRule extends Rule {
  /// Required unless [other] is [expected].
  const RequiredUnlessRule(this.other, Object? expected)
    : _one = expected,
      _many = null;

  /// Required unless [other] is one of [values]
  /// (`required_unless:role,guest,bot`); use [Rules.requiredUnlessIn].
  const RequiredUnlessRule.oneOf(this.other, List<Object?> values)
    : _one = null,
      _many = values;

  final Object? _one;
  final List<Object?>? _many;

  /// The field compared.
  final String other;

  /// The values that make this field optional, as written in the rule.
  List<String> get values => [
    for (final value in _many ?? [_one]) '$value',
  ];

  /// The first of [values].
  Object? get expected => _many == null ? _one : _many.first;

  @override
  String get name => 'required_unless';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {
    'other': other,
    'values': values.join(', '),
  };

  // Laravel's replaceRequiredUnless: the other field's display name and
  // the rule's values, joined.
  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'other': context.displayName(other),
    'values': values.join(', '),
  };

  @override
  String? passes(ValidationContext c) =>
      // 13.x ValidatesAttributes::validateRequiredUnless (2413-2424).
      !_dependentMatches(c, other, values) && isEmptyValue(c.value)
      ? 'required_unless'
      : null;
}

/// [values], refused when empty as Laravel's `requireParameterCount(2)`.
List<Object?> _atLeastOne(String rule, List<Object?> values) =>
    values.isNotEmpty
    ? List.unmodifiable(values)
    : throw ArgumentError.value(
        values,
        'values',
        'Validation rule $rule requires at least 2 parameters.',
      );

/// Whether [other]'s input is one of [values], as Laravel 13.x decides it:
/// `parseDependentRuleParameters` (ValidatesAttributes.php 2470-2485)
/// converts `'true'`/`'false'` to booleans when [other] has a `boolean`
/// rule or its input is a bool, and `'null'` to null when the input is
/// null; then `in_array($other, $values, is_bool($other) ||
/// is_null($other))` compares strictly for a bool or null input and with
/// PHP's loose `==` otherwise.
bool _dependentMatches(ValidationContext c, String other, List<String> values) {
  final input = c.root(other);
  final toBool =
      input is bool ||
      c.booleans.contains(c.resolve(other)) ||
      c.booleans.contains(other);
  final converted = [
    for (final value in values)
      switch (value) {
        'true' when toBool => true,
        'false' when toBool => false,
        _ when input == null && value.toLowerCase() == 'null' => null,
        _ => value,
      },
  ];
  if (input == null || input is bool) {
    return converted.any(
      (value) => value == input && (value == null) == (input == null),
    );
  }
  return converted.any((value) => _phpLooseEquals(input, value));
}

/// PHP 8's `==` between an input value ([a]: a string, number, list or
/// map) and a rule value ([b]: a string or a bool), for `in_array`
/// without strict.
bool _phpLooseEquals(Object a, Object? b) {
  if (b is bool) {
    return _phpTruthy(a) == b;
  }
  if (b is! String) {
    return a == b;
  }
  final bNumber = _phpNumeric(b);
  return switch (a) {
    String() => switch ((_phpNumeric(a), bNumber)) {
      (final num x, final num y) => x == y,
      _ => a == b,
    },
    num() => bNumber != null ? a == bNumber : _phpNumberString(a) == b,
    _ => false,
  };
}

/// PHP's truthiness of an input value: `''`, `'0'`, `0`, `0.0` and an
/// empty list or map are false.
bool _phpTruthy(Object? value) => switch (value) {
  null || false || '' || '0' => false,
  num() => value != 0,
  List<Object?>() => value.isNotEmpty,
  Map<Object?, Object?>() => value.isNotEmpty,
  _ => true,
};

/// The number of a PHP 8 numeric string (`'5'`, `' 1.5 '`, `'1e3'`,
/// `'.5'`), `null` for any other (`'0x1A'`, `'1,5'`, `'abc'`).
num? _phpNumeric(String value) {
  final match = RegExp(
    r'^[ \t\n\r\v\f]*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
    r'[ \t\n\r\v\f]*$',
  ).firstMatch(value);
  if (match == null) {
    return null;
  }
  final text = match[1]!;
  return text.contains(RegExp('[.eE]'))
      ? double.parse(text.endsWith('.') ? '${text}0' : text)
      : int.parse(text);
}

/// A number as PHP writes it in a string comparison (`1.0` is `'1'`).
String _phpNumberString(num value) =>
    value is double && value.isFinite && value == value.truncateToDouble()
    ? value.toInt().toString()
    : '$value';

/// `parseDependentRuleParameters`: with a `boolean` rule on [other], `true`
/// and `false` compare as booleans, so `'1'` matches `true`.
bool _otherMatches(ValidationContext c, String other, List<String> values) {
  final value = c.root(other);
  // Laravel reads the rules of the parameter with `*` replaced; a pattern
  // (`items.*.on`) is kept too.
  if (c.booleans.contains(c.resolve(other)) || c.booleans.contains(other)) {
    final flag = BooleanRule.asBool(value);
    if (flag != null && values.contains('$flag')) {
      return true;
    }
  }
  return values.contains('$value');
}

/// `replaceAcceptedIf`: `:value` is the input, not the rule's argument.
Map<String, Object?> _otherParameters(ValidationContext c, String other) => {
  'other': c.displayName(other),
  'value': switch (c.root(other)) {
    null => 'empty',
    List<Object?>() || Map<Object?, Object?>() => 'array',
    // getDisplayableValue's (string) cast: 5.0 is "5", as PHP writes it.
    final num value => _phpNumberString(value),
    final value => '$value',
  },
};

// `in_array($value, $acceptable, true)`: strict, so 1.0 is neither.
bool _isAccepted(Object? value) => switch (value) {
  bool() => value,
  int() => value == 1,
  String() => const {'yes', 'on', '1', 'true'}.contains(value),
  _ => false,
};

bool _isDeclined(Object? value) => switch (value) {
  bool() => !value,
  int() => value == 0,
  String() => const {'no', 'off', '0', 'false'}.contains(value),
  _ => false,
};

/// `accepted`, `declined` and, with [other], `accepted_if` and `declined_if`
/// (laravel/framework `ValidatesAttributes`, the same from 8 to 13): the
/// value must pass [_test], only while [other] is one of [values] for the
/// conditional rules. Implicit, so a missing attribute fails.
final class AcceptanceRule extends Rule {
  /// `accepted` or `declined`, optionally only when [other] is one of
  /// [values].
  const AcceptanceRule(
    this.name,
    this._test, {
    this.other,
    this.values = const <String>[],
  });

  @override
  final String name;
  final bool Function(Object?) _test;

  /// The field compared, for the `_if` forms.
  final String? other;

  /// The values of [other] that turn the rule on.
  final List<String> values;

  @override
  bool get implicit => true;

  @override
  Map<String, Object?> parametersFor(ValidationContext context) {
    final other = this.other;
    return other == null
        ? const <String, Object?>{}
        : _otherParameters(context, other);
  }

  @override
  String? passes(ValidationContext c) {
    final other = this.other;
    if (other != null && !_otherMatches(c, other, values)) {
      return null;
    }
    return _test(c.value) ? null : name;
  }
}

/// `required_with`: see [Rules.requiredWith].
final class RequiredWithRule extends Rule {
  /// Required when any of [others] is present.
  const RequiredWithRule(this.others);

  /// The fields whose presence requires this one.
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

/// `required_without`: see [Rules.requiredWithout].
final class RequiredWithoutRule extends Rule {
  /// Required when any of [others] is absent.
  const RequiredWithoutRule(this.others);

  /// The fields whose absence requires this one.
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

/// `string`: see [Rules.string].
final class StringRule extends Rule {
  /// The string rule; use [Rules.string].
  const StringRule();
  @override
  String get name => 'string';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'string'};
  @override
  String? passes(ValidationContext c) => c.value is String ? null : 'string';
}

/// `integer`: see [Rules.integer].
final class IntegerRule extends Rule {
  /// The integer rule; use [Rules.integer].
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

/// `numeric`: see [Rules.numeric].
final class NumericRule extends Rule {
  /// The numeric rule; use [Rules.numeric].
  const NumericRule();
  @override
  String get name => 'numeric';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'number'};
  @override
  String? passes(ValidationContext c) =>
      asNum(c.value) == null ? 'numeric' : null;

  /// [value] as a number: itself, or parsed from a string; null otherwise.
  static num? asNum(Object? value) => switch (value) {
    num() => value,
    String() => num.tryParse(value.trim()),
    _ => null,
  };
}

/// `boolean`: see [Rules.boolean].
final class BooleanRule extends Rule {
  /// The boolean rule; use [Rules.boolean].
  const BooleanRule();
  @override
  String get name => 'boolean';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'boolean'};
  @override
  String? passes(ValidationContext c) =>
      asBool(c.value) == null ? 'boolean' : null;

  /// [value] as a boolean, accepting `1`, `0`, `'1'`, `'0'`, `'true'` and
  /// `'false'`; null otherwise.
  static bool? asBool(Object? value) => switch (value) {
    bool() => value,
    1 || '1' || 'true' => true,
    0 || '0' || 'false' => false,
    _ => null,
  };
}

/// `array`, a JSON array or object: see [Rules.array].
final class ArrayRule extends Rule {
  /// The array rule; use [Rules.array].
  const ArrayRule([this.keys]);

  /// The keys allowed (`array:name,email`), or `null` for any.
  final List<String>? keys;
  @override
  String get name => 'array';

  /// No single JSON Schema type: `rulesToJsonSchema` writes
  /// `["array", "object"]` unless nested rules (`field.*`, `field.key`)
  /// say which one.
  @override
  Map<String, Object?> get schemaHint => const {};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    final Iterable<String> present;
    if (value is List<Object?>) {
      present = [for (var i = 0; i < value.length; i++) '$i'];
    } else if (value is Map<Object?, Object?>) {
      present = value.keys.map((k) => '$k');
    } else {
      return 'array';
    }
    final allowed = keys;
    return allowed == null || present.every(allowed.contains) ? null : 'array';
  }
}

/// `list`, a JSON array: see [Rules.list].
final class ListRule extends Rule {
  /// The list rule; use [Rules.list].
  const ListRule();
  @override
  String get name => 'list';
  @override
  Map<String, Object?> get schemaHint => const {'type': 'array'};
  @override
  String? passes(ValidationContext c) =>
      c.value is List<Object?> ? null : 'list';
}

/// `map`, a JSON object: see [Rules.map].
final class MapRule extends Rule {
  /// The map rule; use [Rules.map].
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

/// `email` and `email:rfc,dns,...`: see [Rules.email].
///
/// As Laravel's `validateEmail`: the value is a string without `\r` or
/// `\n`, and passes **every** mode in [modes] (`rfc` when none is given; a
/// name Laravel does not know is `rfc`, as Laravel's `default` arm).
final class EmailRule extends Rule {
  /// The email rule; use [Rules.email].
  const EmailRule({this.modes = const <String>{}});

  /// The modes, by Laravel's names: `rfc`, `strict`, `dns`, `spoof`,
  /// `filter`, `filter_unicode`.
  final Set<String> modes;

  /// The rule with [modes], refusing `spoof` at once: [Rules.email] and
  /// the string parser build it this way, so the error comes when the
  /// rules are built (a `Validator`, OpenAPI), not on each value checked.
  static EmailRule checked(Set<String> modes) {
    if (modes.contains('spoof')) {
      throw UnsupportedError(_spoofUnsupported);
    }
    return EmailRule(modes: modes);
  }

  static const String _spoofUnsupported =
      'email:spoof needs ICU\'s Spoofchecker, which Dart does not have; '
      'Daravel does not check it (dartisan lint reports it).';

  /// The modes Daravel checks; `spoof` throws [UnsupportedError].
  static const Set<String> knownModes = {
    'rfc',
    'strict',
    'dns',
    'spoof',
    'filter',
    'filter_unicode',
  };

  // `rfc` and `strict` until egulias/EmailValidator's RFC parser is ported:
  // an address of HTML's `type=email` (no quoted local part, no domain
  // literal, at least two labels), stricter than egulias' RFCValidation.
  static final RegExp _rfc = RegExp(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
  );

  /// The pattern a client checks before sending (`dartisan client:flutter`
  /// writes it into the Flutter form validators); the server's check,
  /// with its modes, decides.
  RegExp get pattern => _rfc;

  @override
  String get name => 'email';

  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'email',
  };

  @override
  Future<String?> passes(ValidationContext context) async {
    final value = context.value;
    if (value is! String || value.contains('\r') || value.contains('\n')) {
      return name;
    }
    final checks = {
      for (final mode in modes.isEmpty ? const {'rfc'} : modes)
        knownModes.contains(mode) ? mode : 'rfc',
    };
    // Reached only by a `const EmailRule(modes: {'spoof'})` built directly.
    if (checks.contains('spoof')) {
      throw UnsupportedError(_spoofUnsupported);
    }
    if ((checks.contains('rfc') || checks.contains('strict')) &&
        !_rfc.hasMatch(value)) {
      return name;
    }
    // PHP's FILTER_VALIDATE_EMAIL, read in one pass: PHP's regex
    // backtracks exponentially, and Dart's engine has no limit to stop it.
    if (checks.contains('filter') && !phpFilterEmail(value)) {
      return name;
    }
    if (checks.contains('filter_unicode') &&
        !phpFilterEmail(value, unicode: true)) {
      return name;
    }
    // Last, so an address that fails the cheap checks costs no lookup.
    if (checks.contains('dns') &&
        !await emailDomainResolves(value, _resolver(context))) {
      return name;
    }
    return null;
  }
}

/// The [DnsResolver] bound in the container of [context], or the shared
/// [SystemDnsResolver].
DnsResolver _resolver(ValidationContext context) =>
    context.container?.tryMake<DnsResolver>() ?? SystemDnsResolver.instance;

/// `active_url`: see [Rules.activeUrl].
final class ActiveUrlRule extends Rule {
  /// The active URL rule; use [Rules.activeUrl].
  const ActiveUrlRule();

  @override
  String get name => 'active_url';

  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'uri',
  };

  @override
  Future<String?> passes(ValidationContext context) async {
    // Laravel: the host of parse_url, then dns_get_record(host, A|AAAA).
    // An IP address is not a name DNS answers for, so it fails without a
    // lookup, as it does in Laravel; so does a name DNS cannot carry.
    final value = context.value;
    if (value is! String) {
      return name;
    }
    final host = Uri.tryParse(value)?.host ?? '';
    if (host.isEmpty || isIpLiteral(host)) {
      return name;
    }
    final ascii = toAsciiHost(host);
    if (ascii == null) {
      return name;
    }
    return await _resolver(context).hasAddress(ascii) ? null : name;
  }
}

/// `url`: see [Rules.url].
final class UrlRule extends Rule {
  /// The URL rule; use [Rules.url].
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

/// `uuid`: see [Rules.uuid].
final class UuidRule extends _PatternRule {
  /// The UUID rule; use [Rules.uuid].
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

/// `ulid`: see [Rules.ulid].
final class UlidRule extends _PatternRule {
  /// The ULID rule; use [Rules.ulid].
  const UlidRule();
  static final RegExp _ulid = RegExp(
    r'^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$',
  );
  @override
  String get name => 'ulid';
  @override
  RegExp get pattern => _ulid;
}

/// `ip`, `ipv4` and `ipv6`: see [Rules.ip].
final class IpRule extends Rule {
  /// An address of IP [version] 4 or 6, or either when null.
  const IpRule({this.version});

  /// 4, 6, or null for either.
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

/// `json`: see [Rules.json].
final class JsonRule extends Rule {
  /// The JSON rule; use [Rules.json].
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

/// `alpha`: see [Rules.alpha].
final class AlphaRule extends _PatternRule {
  /// The alpha rule; use [Rules.alpha].
  const AlphaRule();
  static final RegExp _alpha = RegExp(r'^[\p{L}\p{M}]+$', unicode: true);
  @override
  String get name => 'alpha';
  @override
  RegExp get pattern => _alpha;
}

/// `alpha_num`: see [Rules.alphaNum].
final class AlphaNumRule extends _PatternRule {
  /// The alpha_num rule; use [Rules.alphaNum].
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

/// `alpha_dash`: see [Rules.alphaDash].
final class AlphaDashRule extends _PatternRule {
  /// The alpha_dash rule; use [Rules.alphaDash].
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

/// `ascii`: see [Rules.ascii].
final class AsciiRule extends _PatternRule {
  /// The ASCII rule; use [Rules.ascii].
  const AsciiRule();
  static final RegExp _ascii = RegExp(r'^[\x00-\x7F]*$');
  @override
  String get name => 'ascii';
  @override
  RegExp get pattern => _ascii;
}

/// `lowercase`: see [Rules.lowercase].
final class LowercaseRule extends Rule {
  /// The lowercase rule; use [Rules.lowercase].
  const LowercaseRule();
  @override
  String get name => 'lowercase';
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && value == value.toLowerCase() ? null : 'lowercase';
  }
}

/// `uppercase`: see [Rules.uppercase].
final class UppercaseRule extends Rule {
  /// The uppercase rule; use [Rules.uppercase].
  const UppercaseRule();
  @override
  String get name => 'uppercase';
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && value == value.toUpperCase() ? null : 'uppercase';
  }
}

/// `regex` and `not_regex`: see [Rules.regex].
final class RegexRule extends Rule {
  /// Matches [pattern], or must not when [negate].
  const RegexRule(this.pattern, {this.negate = false});

  /// The pattern tested.
  final RegExp pattern;

  /// Whether a match fails the rule (`not_regex`).
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
/// Uploaded files by size in kilobytes, as Laravel measures them.
num? sizeOf(Object? value, {bool numeric = false}) => switch (value) {
  num() => value,
  UploadedFile() => value.size / 1024,
  // With a `numeric`/`integer` rule on the attribute a string is measured
  // by its value, as Laravel's getSize does: every form and query input
  // is a string, so `numeric|max:100` must bound "500" by 500, not by its
  // three characters.
  String() when numeric => num.tryParse(value.trim()) ?? value.runes.length,
  String() => value.runes.length,
  List<Object?>() => value.length,
  Map<Object?, Object?>() => value.length,
  _ => null,
};

String _sizeKind(Object? value, {bool numeric = false}) => switch (value) {
  num() => 'numeric',
  String() when numeric && num.tryParse(value.trim()) != null => 'numeric',
  UploadedFile() => 'file',
  List<Object?>() || Map<Object?, Object?>() => 'array',
  _ => 'string',
};

/// `min`: see [Rules.min].
final class MinRule extends Rule {
  /// At least [min].
  const MinRule(this.min);

  /// The smallest size allowed.
  final num min;
  @override
  String get name => 'min';
  @override
  Map<String, Object?> get parameters => {'min': min};
  @override
  Map<String, Object?> get schemaHint => {'minimum': min, 'minLength': min};
  @override
  String? passes(ValidationContext c) {
    final size = sizeOf(c.value, numeric: c.numeric);
    return size != null && size >= min
        ? null
        : 'min.${_sizeKind(c.value, numeric: c.numeric)}';
  }
}

/// `max`: see [Rules.max].
final class MaxRule extends Rule {
  /// At most [max].
  const MaxRule(this.max);

  /// The largest size allowed.
  final num max;
  @override
  String get name => 'max';
  @override
  Map<String, Object?> get parameters => {'max': max};
  @override
  Map<String, Object?> get schemaHint => {'maximum': max, 'maxLength': max};
  @override
  String? passes(ValidationContext c) {
    final size = sizeOf(c.value, numeric: c.numeric);
    return size != null && size <= max
        ? null
        : 'max.${_sizeKind(c.value, numeric: c.numeric)}';
  }
}

/// `between`: see [Rules.between].
final class BetweenRule extends Rule {
  /// From [min] to [max] inclusive.
  const BetweenRule(this.min, this.max);

  /// The smallest size allowed.
  final num min;

  /// The largest size allowed.
  final num max;
  @override
  String get name => 'between';
  @override
  Map<String, Object?> get parameters => {'min': min, 'max': max};
  @override
  String? passes(ValidationContext c) {
    final size = sizeOf(c.value, numeric: c.numeric);
    return size != null && size >= min && size <= max
        ? null
        : 'between.${_sizeKind(c.value, numeric: c.numeric)}';
  }
}

/// `size`: see [Rules.size].
final class SizeRule extends Rule {
  /// Exactly [size].
  const SizeRule(this.size);

  /// The size required.
  final num size;
  @override
  String get name => 'size';
  @override
  Map<String, Object?> get parameters => {'size': size};
  @override
  String? passes(ValidationContext c) =>
      sizeOf(c.value, numeric: c.numeric) == size
      ? null
      : 'size.${_sizeKind(c.value, numeric: c.numeric)}';
}

/// `digits`: see [Rules.digits].
final class DigitsRule extends Rule {
  /// An integer of exactly [length] digits.
  const DigitsRule(this.length);

  /// The number of digits.
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

/// `digits_between`: see [Rules.digitsBetween].
final class DigitsBetweenRule extends Rule {
  /// An integer of [min] to [max] digits.
  const DigitsBetweenRule(this.min, this.max);

  /// The fewest digits.
  final int min;

  /// The most digits.
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

/// `in` and `not_in`: see [Rules.inList].
final class InRule extends Rule {
  /// One of [values], or none of them when [negate].
  const InRule(this.values, {this.negate = false});

  /// The values listed.
  final List<Object?> values;

  /// Whether it is `not_in`.
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

/// `distinct`: see [Rules.distinct].
final class DistinctRule extends Rule {
  /// The distinct rule; use [Rules.distinct].
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

/// `confirmed`: see [Rules.confirmed].
final class ConfirmedRule extends Rule {
  /// Equal to [field], or to `<attribute>_confirmation`.
  const ConfirmedRule([this.field]);

  /// The confirming field, when not `<attribute>_confirmation`.
  final String? field;
  @override
  String get name => 'confirmed';
  @override
  String? passes(ValidationContext c) {
    final other = field ?? '${c.attribute}_confirmation';
    return '${c.root(other)}' == '${c.value}' ? null : 'confirmed';
  }
}

/// `same` and `different`: see [Rules.same].
final class SameRule extends Rule {
  /// Equal to [other], or different when [negate].
  const SameRule(this.other, {this.negate = false});

  /// The field compared.
  final String other;

  /// Whether it is `different`.
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

/// `starts_with`: see [Rules.startsWith].
final class StartsWithRule extends Rule {
  /// Starts with one of [prefixes].
  const StartsWithRule(this.prefixes);

  /// The prefixes accepted.
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

/// `ends_with`: see [Rules.endsWith].
final class EndsWithRule extends Rule {
  /// Ends with one of [suffixes].
  const EndsWithRule(this.suffixes);

  /// The suffixes accepted.
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

/// `date`: see [Rules.date].
final class DateRule extends Rule {
  /// The date rule; use [Rules.date].
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

/// `after`, `after_or_equal`, `before`, `before_or_equal` and
/// `date_equals`.
final class DateCompareRule extends Rule {
  /// Compares the date with [dateOrField] by [operator].
  const DateCompareRule(this.operator, this.dateOrField);

  /// The rule name: `after`, `before`, `after_or_equal`...
  final String operator;

  /// A date (`'2026-01-01'`, `'today'`, `'tomorrow'`) or another field.
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
      'date_equals' => value.isAtSameMomentAs(other),
      _ => false,
    };
    return ok ? null : operator;
  }
}

// ---------------------------------------------------------------------------
// Comparisons (laravel/framework `ValidatesAttributes`)
// ---------------------------------------------------------------------------

/// An exact decimal, as Brick's `BigDecimal` in Laravel: `0.3` is a multiple
/// of `0.1` here, and never in floating point. `null` unless `is_numeric`.
(BigInt, int)? _decimalOf(Object? value) {
  if (value is! String && value is! num) {
    return null;
  }
  final match = RegExp(
    r'^\s*([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d{1,4}))?\s*$',
  ).firstMatch('$value');
  if (match == null) {
    return null;
  }
  final whole = match[2]!;
  final fraction = match[3] ?? '';
  if (whole.isEmpty && fraction.isEmpty) {
    return null;
  }
  final digits = BigInt.parse('$whole$fraction');
  final exponent = int.parse(match[4] ?? '0');
  var scale = fraction.length - exponent;
  var unscaled = match[1] == '-' ? -digits : digits;
  if (scale < 0) {
    unscaled *= BigInt.from(10).pow(-scale);
    scale = 0;
  }
  return (unscaled, scale);
}

/// Both at the larger scale, so they compare as integers.
(BigInt, BigInt) _aligned((BigInt, int) a, (BigInt, int) b) {
  final scale = a.$2 > b.$2 ? a.$2 : b.$2;
  BigInt at((BigInt, int) n) => n.$1 * BigInt.from(10).pow(scale - n.$2);
  return (at(a), at(b));
}

/// PHP's `gettype` equality (`isSameType`): an int and a float differ.
bool _sameType(Object? a, Object? b) => switch ((a, b)) {
  (int(), int()) || (double(), double()) || (String(), String()) => true,
  (List<Object?>() || Map<Object?, Object?>(), List<Object?>()) => true,
  (List<Object?>() || Map<Object?, Object?>(), Map<Object?, Object?>()) => true,
  (UploadedFile(), UploadedFile()) => true,
  _ => false,
};

/// `gt`, `gte`, `lt` and `lte`: against another field of the same type, or a
/// number when the value is numeric too.
final class CompareRule extends Rule {
  /// The comparison [name] (`gt`, `gte`, `lt`, `lte`) against [target].
  const CompareRule(this.name, this.target);
  @override
  final String name;

  /// Another field, or a number.
  final String target;

  bool _holds(int order) => switch (name) {
    'gt' => order > 0,
    'gte' => order >= 0,
    'lt' => order < 0,
    _ => order <= 0,
  };

  @override
  Map<String, Object?> parametersFor(ValidationContext context) {
    final compared = context.root(target);
    final numeric = context.numeric || _decimalOf(context.value) != null;
    return {
      'value': compared == null
          ? context.displayName(target)
          : sizeOf(compared, numeric: numeric),
    };
  }

  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    final compared = c.root(target);
    final literal = _decimalOf(target);
    final decimal = _decimalOf(value);
    final numeric = c.numeric || decimal != null;
    final failure = '$name.${_sizeKind(value, numeric: numeric)}';
    if (literal != null) {
      if (compared != null || decimal == null) {
        return failure;
      }
      final (a, b) = _aligned(decimal, literal);
      return _holds(a.compareTo(b)) ? null : failure;
    }
    final other = _decimalOf(compared);
    if (decimal != null && other != null) {
      final (a, b) = _aligned(decimal, other);
      return _holds(a.compareTo(b)) ? null : failure;
    }
    if (!_sameType(value, compared)) {
      return failure;
    }
    final size = sizeOf(value, numeric: numeric);
    final otherSize = sizeOf(compared, numeric: numeric);
    return size != null &&
            otherSize != null &&
            _holds(size.compareTo(otherSize))
        ? null
        : failure;
  }
}

/// `decimal:2` and `decimal:0,4`.
final class DecimalRule extends Rule {
  /// [min] to [max] digits after the decimal point.
  const DecimalRule(this.min, [this.max]);

  /// The fewest digits after the point.
  final int min;

  /// The most digits after the point; exactly [min] when null.
  final int? max;
  @override
  String get name => 'decimal';
  @override
  Map<String, Object?> get parameters => {
    'decimal': max == null ? '$min' : '$min-$max',
  };
  @override
  String? passes(ValidationContext c) {
    final match = RegExp(r'^[+-]?\d*\.?(\d*)$').firstMatch('${c.value}');
    if (_decimalOf(c.value) == null || match == null) {
      return 'decimal';
    }
    final places = match[1]!.length;
    final ok = max == null ? places == min : places >= min && places <= max!;
    return ok ? null : 'decimal';
  }
}

/// `multiple_of`: see [Rules.multipleOf].
final class MultipleOfRule extends Rule {
  /// A multiple of [factor].
  const MultipleOfRule(this.factor);

  /// The factor, a number.
  final Object factor;
  @override
  String get name => 'multiple_of';
  @override
  Map<String, Object?> get parameters => {'value': factor};
  @override
  String? passes(ValidationContext c) {
    final value = _decimalOf(c.value);
    final divisor = _decimalOf(factor);
    if (value == null || divisor == null) {
      return 'multiple_of';
    }
    if (divisor.$1 == BigInt.zero) {
      return 'multiple_of';
    }
    final (a, b) = _aligned(value, divisor);
    return a.remainder(b) == BigInt.zero ? null : 'multiple_of';
  }
}

/// `min_digits` and `max_digits`: the length of a number made of digits.
final class DigitCountRule extends Rule {
  /// `min_digits` or `max_digits` ([name]) with [limit].
  const DigitCountRule(this.name, this.limit);
  @override
  final String name;

  /// The digit limit.
  final int limit;
  @override
  Map<String, Object?> get parameters => {
    name == 'min_digits' ? 'min' : 'max': limit,
  };
  @override
  String? passes(ValidationContext c) {
    final text = '${c.value}';
    final ok = name == 'min_digits'
        ? text.length >= limit
        : text.length <= limit;
    return ok && !text.contains(RegExp('[^0-9]')) ? null : name;
  }
}

/// PHP's `timezone_identifiers_list` by the group of the name. The database
/// here also knows old aliases such as `Asia/Calcutta`, which PHP's list
/// leaves out.
final class TimezoneRule extends Rule {
  /// A time zone of [group].
  const TimezoneRule([this.group = 'all']);

  /// `all`, or a region such as `Asia` or `Europe`.
  final String group;
  @override
  String get name => 'timezone';
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    final ok =
        value is String &&
        Clock.isTimeZone(value) &&
        (group == 'all' || value.toLowerCase().startsWith(group.toLowerCase()));
    return ok ? null : 'timezone';
  }
}

/// `Rule::enum()`: the value of one of [values], by name or by [toValue].
final class EnumRule<E extends Enum> extends Rule {
  /// One of [values], mapped by [toValue] when the stored value is not the
  /// name; [only] and [except] narrow the allowed values.
  const EnumRule(this.values, {this.toValue, this.only, this.except});

  /// Every value of the enum.
  final List<E> values;

  /// The input form of a value (its name when null).
  final Object? Function(E value)? toValue;

  /// When set, the only values allowed.
  final List<E>? only;

  /// Values refused.
  final List<E>? except;
  @override
  String get name => 'enum';
  @override
  Map<String, Object?> get schemaHint => {
    'enum': [for (final e in _allowed) _wire(e)],
  };

  Iterable<E> get _allowed => values.where(
    (e) => (only?.contains(e) ?? true) && !(except?.contains(e) ?? false),
  );

  Object? _wire(E value) => toValue?.call(value) ?? value.name;

  @override
  String? passes(ValidationContext c) =>
      _allowed.any((e) => '${_wire(e)}' == '${c.value}') ? null : 'enum';
}

/// `prohibited_if`, `prohibited_unless` and `present_if`.
final class DependentRule extends Rule {
  /// A rule [name] that applies when [other] is one of [values].
  const DependentRule(this.name, this.other, this.values);
  @override
  final String name;

  /// The field compared.
  final String other;

  /// The values of [other] that turn the rule on.
  final List<String> values;

  @override
  Map<String, Object?> parametersFor(ValidationContext context) =>
      switch (name) {
        'prohibited_unless' => {
          'other': context.displayName(other),
          'values': values.join(', '),
        },
        // `replaceMissingUnless`: `:value` is the rule's first value, not
        // the input.
        'missing_unless' || 'present_unless' => {
          'other': context.displayName(other),
          'value': values.isEmpty ? '' : values.first,
        },
        _ => _otherParameters(context, other),
      };

  // Laravel's `Validator::$implicitRules` holds the presence forms, not
  // the prohibited ones.
  @override
  bool get implicit =>
      name.startsWith('present_') || name.startsWith('missing_');

  @override
  String? passes(ValidationContext c) {
    final matches = _otherMatches(c, other, values);
    return switch (name) {
      'present_if' => matches && !c.present ? name : null,
      'present_unless' => !matches && !c.present ? name : null,
      'missing_if' => matches && c.present ? name : null,
      'missing_unless' => !matches && c.present ? name : null,
      'prohibited_if' => matches && !isEmptyValue(c.value) ? name : null,
      _ => !matches && !isEmptyValue(c.value) ? name : null,
    };
  }
}

/// `missing`: see [Rules.missing].
final class MissingRule extends Rule {
  /// The missing rule; use [Rules.missing].
  const MissingRule();
  @override
  String get name => 'missing';
  @override
  bool get implicit => true;
  @override
  String? passes(ValidationContext c) => c.present ? 'missing' : null;
}

/// `missing_with`, `missing_with_all`, `present_with` and
/// `present_with_all`: the key must be missing (or present) while any (or
/// all) of [others] are in the input. Presence is the key's, as Laravel's
/// `Arr::hasAny`/`Arr::has`: a key with a null or empty value counts.
final class PresenceWithRule extends Rule {
  /// The rule [name] over [others].
  const PresenceWithRule(this.name, this.others);
  @override
  final String name;

  /// The fields whose presence turns the rule on.
  final List<String> others;

  @override
  bool get implicit => true;

  // `replaceMissingWith` / `replacePresentWith`: display names joined with
  // ' / '.
  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'values': others.map(context.displayName).join(' / '),
  };

  @override
  String? passes(ValidationContext c) {
    final on = name.endsWith('_all') ? others.every(c.has) : others.any(c.has);
    if (!on) {
      return null;
    }
    final mustBeMissing = name.startsWith('missing');
    return c.present == mustBeMissing ? name : null;
  }
}

/// `prohibited_if_accepted`, `prohibited_if_declined` and
/// `required_if_declined`: [other] accepted (or declined) makes this field
/// prohibited (or required).
final class AcceptanceConditionRule extends Rule {
  /// The rule [name] on [other].
  const AcceptanceConditionRule(this.name, this.other);
  @override
  final String name;

  /// The field that must be accepted or declined.
  final String other;

  // Only `required_if_declined` is in Laravel's `$implicitRules`.
  @override
  bool get implicit => name == 'required_if_declined';

  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'other': context.displayName(other),
  };

  @override
  String? passes(ValidationContext c) {
    final otherValue = c.root(other);
    final on = name == 'prohibited_if_accepted'
        ? _isAccepted(otherValue)
        : _isDeclined(otherValue);
    if (!on) {
      return null;
    }
    final empty = isEmptyValue(c.value);
    return (name == 'required_if_declined' ? empty : !empty) ? name : null;
  }
}

/// `required_array_keys`: see [Rules.requiredArrayKeys].
final class RequiredArrayKeysRule extends Rule {
  /// An array with every one of [keys].
  const RequiredArrayKeysRule(this.keys);

  /// The keys the array must have.
  final List<String> keys;
  @override
  String get name => 'required_array_keys';
  @override
  Map<String, Object?> get parameters => {'values': keys.join(', ')};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    bool has(String key) => switch (value) {
      Map<Object?, Object?>() => value.containsKey(key),
      // `array_key_exists` on a list: only the canonical integer form of an
      // index matches ('1', not '01' or '+1').
      List<Object?>() => switch (int.tryParse(key)) {
        final int i => '$i' == key && i >= 0 && i < value.length,
        null => false,
      },
      _ => false,
    };
    final isArray = value is Map<Object?, Object?> || value is List<Object?>;
    return isArray && keys.every(has) ? null : name;
  }
}

/// `prohibits`: the others must be empty while this one is not.
final class ProhibitsRule extends Rule {
  /// When present, every one of [others] must be absent.
  const ProhibitsRule(this.others);

  /// The fields that must be absent.
  final List<String> others;
  @override
  String get name => 'prohibits';
  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'other': others.map(context.displayName).join(' / '),
  };
  @override
  String? passes(ValidationContext c) =>
      !isEmptyValue(c.value) && others.any((o) => !isEmptyValue(c.root(o)))
      ? 'prohibits'
      : null;
}

/// `required_with_all`: see [Rules.requiredWithAll].
final class RequiredWithAllRule extends Rule {
  /// Required when all of [others] are present.
  const RequiredWithAllRule(this.others);

  /// The fields that together require this one.
  final List<String> others;
  @override
  String get name => 'required_with_all';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {'values': others.join(' / ')};
  @override
  String? passes(ValidationContext c) =>
      others.every((o) => !isEmptyValue(c.root(o))) && isEmptyValue(c.value)
      ? name
      : null;
}

/// `required_without_all`: see [Rules.requiredWithoutAll].
final class RequiredWithoutAllRule extends Rule {
  /// Required when none of [others] is present.
  const RequiredWithoutAllRule(this.others);

  /// The fields whose absence requires this one.
  final List<String> others;
  @override
  String get name => 'required_without_all';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> get parameters => {'values': others.join(' / ')};
  @override
  String? passes(ValidationContext c) =>
      others.every((o) => isEmptyValue(c.root(o))) && isEmptyValue(c.value)
      ? name
      : null;
}

/// `required_if_accepted`: see [Rules.requiredIfAccepted].
final class RequiredIfAcceptedRule extends Rule {
  /// Required when [other] is accepted.
  const RequiredIfAcceptedRule(this.other);

  /// The field that must be accepted.
  final String other;
  @override
  String get name => 'required_if_accepted';
  @override
  bool get implicit => true;
  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'other': context.displayName(other),
  };
  @override
  String? passes(ValidationContext c) =>
      _isAccepted(c.root(other)) && isEmptyValue(c.value) ? name : null;
}

/// The rules that drop an attribute: [passes] answers its name when the
/// attribute leaves the validated data, and no error is added.
final class ExcludeRule extends Rule {
  /// The exclude rule [name], conditioned on [other] and [values].
  const ExcludeRule(this.name, {this.other, this.values = const <String>[]});
  @override
  final String name;

  /// The field compared, for the conditional forms.
  final String? other;

  /// The values of [other] that exclude the field.
  final List<String> values;

  /// `Validator::$excludeRules`.
  static const Set<String> names = {
    'exclude',
    'exclude_if',
    'exclude_unless',
    'exclude_with',
    'exclude_without',
  };

  // `isValidatable` always runs them, also on an empty value.
  @override
  bool get implicit => true;

  @override
  String? passes(ValidationContext c) {
    final other = this.other;
    final excluded = switch (name) {
      // `has` resolves `*` to the attribute's own item, as Laravel's
      // replaceAsterisksInParameters does for these dependent rules.
      'exclude_if' => c.has(other!) && _otherMatches(c, other, values),
      'exclude_unless' => !_otherMatches(c, other!, values),
      'exclude_with' => c.has(other!),
      'exclude_without' => isEmptyValue(c.root(other!)),
      _ => true,
    };
    return excluded ? name : null;
  }
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

String _identifier(String identifier) {
  if (!_identifierPattern.hasMatch(identifier)) {
    throw ArgumentError.value(
      identifier,
      'identifier',
      'Invalid SQL identifier',
    );
  }
  return identifier;
}

/// `table` or `schema.table`, as Laravel's `parseTable` allows.
String _table(String table) {
  table.split('.').forEach(_identifier);
  return table;
}

/// A condition added to the query of [UniqueRule] or [ExistsRule]:
/// `Rules.unique('users').where((q) => q.where('active', true))`.
typedef QueryConstraint = Object? Function(QueryBuilder query);

QueryBuilder _constrained(
  QueryBuilder query,
  List<QueryConstraint> constraints,
) {
  var result = query;
  for (final constraint in constraints) {
    final next = constraint(result);
    if (next is QueryBuilder) {
      result = next;
    }
  }
  return result;
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
  /// No row of [table] holds the value in [column]; see [Rules.unique].
  const UniqueRule(
    this.table, {
    this.column,
    Object? ignore,
    this.idColumn = 'id',
    this.constraints = const <QueryConstraint>[],
  }) : ignored = ignore;

  /// The table queried; `schema.table` is allowed.
  final String table;

  /// The column checked; the field's name when null.
  final String? column;

  /// The key of the row to skip, for updates.
  final Object? ignored;

  /// The key column of [ignored].
  final String idColumn;

  /// Extra conditions on the query.
  final List<QueryConstraint> constraints;

  /// `->ignore($id, 'staff_id')`: skips the row being edited.
  UniqueRule ignore(Object? id, {String? idColumn}) => UniqueRule(
    table,
    column: column,
    ignore: id,
    idColumn: idColumn ?? this.idColumn,
    constraints: constraints,
  );

  /// `->where(fn ($q) => $q->whereNull('deleted_at'))`.
  UniqueRule where(QueryConstraint constraint) => UniqueRule(
    table,
    column: column,
    ignore: ignored,
    idColumn: idColumn,
    constraints: [...constraints, constraint],
  );
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
    // The builder quotes identifiers for the connection's dialect.
    var query = db.table(_table(table)).where(_identifier(col), c.value);
    if (ignored != null) {
      query = query.where(_identifier(idColumn), '<>', ignored);
    }
    query = _constrained(query, constraints);
    return await query.count() > 0 ? 'unique' : null;
  }
}

/// `exists:table,column` — the value must be present in the table.
final class ExistsRule extends Rule {
  /// A row of [table] holds the value in [column]; see [Rules.exists].
  const ExistsRule(
    this.table, {
    this.column,
    this.constraints = const <QueryConstraint>[],
  });

  /// The table queried.
  final String table;

  /// The column checked; the field's name when null.
  final String? column;

  /// Extra conditions on the query.
  final List<QueryConstraint> constraints;

  /// `->where(fn ($q) => $q->whereNull('deleted_at'))`.
  ExistsRule where(QueryConstraint constraint) => ExistsRule(
    table,
    column: column,
    constraints: [...constraints, constraint],
  );
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
    final count = await _constrained(
      db.table(_table(table)).where(_identifier(col), c.value),
      constraints,
    ).count();
    return count > 0 ? null : 'exists';
  }
}

// ---------------------------------------------------------------------------
// Passwords & closures
// ---------------------------------------------------------------------------

/// `Password`: see [Rules.password].
final class PasswordRule extends Rule {
  /// A password of at least [min] characters with the asked kinds.
  const PasswordRule({
    this.min = 8,
    this.letters = false,
    this.mixedCase = false,
    this.numbers = false,
    this.symbols = false,
  });

  /// The fewest characters.
  final int min;

  /// Whether at least one letter is required.
  final bool letters;

  /// Whether upper and lower case letters are both required.
  final bool mixedCase;

  /// Whether at least one digit is required.
  final bool numbers;

  /// Whether at least one symbol is required.
  final bool symbols;
  @override
  String get name => 'password';
  @override
  Map<String, Object?> get parameters => {'min': min};
  @override
  Map<String, Object?> get schemaHint => {
    'type': 'string',
    'format': 'password',
    'minLength': min,
  };
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

/// A rule from a closure: see [Rules.custom].
final class ClosureRule extends Rule {
  /// Runs [check]; [name] keys the rule's message.
  const ClosureRule(this.check, {this.name = 'custom'});

  /// Returns an error message, or null when the value passes.
  final FutureOr<String?> Function(ValidationContext context) check;
  @override
  final String name;
  @override
  FutureOr<String?> passes(ValidationContext c) => check(c);
}

// ---------------------------------------------------------------------------
// Files (Laravel 12 ValidatesAttributes: validateFile, validateImage,
// validateMimes, validateMimetypes, validateExtensions)
// ---------------------------------------------------------------------------

const Set<String> _phpExtensions = {
  'php',
  'php3',
  'php4',
  'php5',
  'php7',
  'php8',
  'phtml',
  'phar',
};

/// Laravel refuses PHP uploads unless `php` is listed explicitly.
bool _blocksPhp(UploadedFile file, List<String> allowed) =>
    !allowed.contains('php') &&
    _phpExtensions.contains(file.clientExtension.trim());

/// `file`: see [Rules.file].
final class FileRule extends Rule {
  /// The file rule; use [Rules.file].
  const FileRule();
  @override
  String get name => 'file';
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'binary',
  };
  @override
  String? passes(ValidationContext c) => c.value is UploadedFile ? null : name;
}

/// `mimes:jpg,png`: the extension guessed from the content.
final class MimesRule extends Rule {
  /// An upload whose content matches one of [extensions]; [ruleName] keys
  /// the message.
  const MimesRule(this.extensions, {this.ruleName = 'mimes'});

  /// The extensions accepted, such as `pdf` or `jpg`.
  final List<String> extensions;

  /// The rule name used for messages: `mimes` or `image`.
  final String ruleName;
  @override
  String get name => ruleName;
  @override
  Map<String, Object?> get parameters => {'values': extensions.join(', ')};
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'binary',
  };
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! UploadedFile || _blocksPhp(value, extensions)) {
      return name;
    }
    final allowed = {...extensions};
    if (allowed.contains('jpg') || allowed.contains('jpeg')) {
      allowed.addAll(['jpg', 'jpeg']);
    }
    return allowed.contains(value.extension) ? null : name;
  }
}

/// `image` (jpg, jpeg, png, gif, bmp, webp; `image:allow_svg` adds svg).
final class ImageRule extends MimesRule {
  /// An image upload; svg only when [allowSvg].
  const ImageRule({bool allowSvg = false})
    : super(allowSvg ? _withSvg : _images, ruleName: 'image');
  static const List<String> _images = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'webp',
  ];
  static const List<String> _withSvg = [..._images, 'svg'];
  @override
  Map<String, Object?> get parameters => const {};
}

/// `mimetypes:image/jpeg,video/*`: the type detected from the content.
final class MimetypesRule extends Rule {
  /// An upload of one of the MIME [types].
  const MimetypesRule(this.types);

  /// The MIME types accepted, such as `application/pdf`.
  final List<String> types;
  @override
  String get name => 'mimetypes';
  @override
  Map<String, Object?> get parameters => {'values': types.join(', ')};
  @override
  Map<String, Object?> get schemaHint => const {
    'type': 'string',
    'format': 'binary',
  };
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! UploadedFile || _blocksPhp(value, types)) {
      return name;
    }
    final type = value.mimeType;
    final family = '${type.split('/').first}/*';
    return types.contains(type) || types.contains(family) ? null : name;
  }
}

/// `extensions:csv,txt`: the extension of the client's file name.
final class ExtensionsRule extends Rule {
  /// An upload whose file name ends with one of [extensions].
  const ExtensionsRule(this.extensions);

  /// The extensions accepted.
  final List<String> extensions;
  @override
  String get name => 'extensions';
  @override
  Map<String, Object?> get parameters => {'values': extensions.join(', ')};
  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! UploadedFile || _blocksPhp(value, extensions)) {
      return name;
    }
    return extensions.contains(value.clientExtension) ? null : name;
  }
}

/// `date_format:Y-m-d[,d/m/Y]`: the value, a string or a number, reads
/// back exactly in one of [formats] (Laravel's `validateDateFormat`).
final class DateFormatRule extends Rule {
  /// A date in one of the PHP `date()` [formats].
  DateFormatRule(this.formats) {
    if (formats.isEmpty) {
      throw ArgumentError.value(
        formats,
        'formats',
        'date_format needs at least one format',
      );
    }
  }

  /// The PHP `date()` formats accepted.
  final List<String> formats;

  @override
  String get name => 'date_format';

  @override
  Map<String, Object?> get parameters => {'format': formats.first};

  @override
  Map<String, Object?> get schemaHint => const {'type': 'string'};

  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! String && value is! num) {
      return 'date_format';
    }
    final text = '$value';
    return formats.any((format) => phpDateMatchesFormat(text, format))
        ? null
        : 'date_format';
  }
}

// ---------------------------------------------------------------------------
// Laravel 13 content rules (W9.4a)
// ---------------------------------------------------------------------------

/// [value] as PHP's loose `==` sees it against a rule's string parameter:
/// the same text, or the same number.
bool _looselyEquals(Object? value, String parameter) {
  if ('$value' == parameter) {
    return true;
  }
  final number = num.tryParse(parameter);
  return number != null && value is num && value == number;
}

/// The values of an array (JSON list or object), or null for anything else.
Iterable<Object?>? _arrayValues(Object? value) => switch (value) {
  List<Object?>() => value,
  Map<Object?, Object?>() => value.values,
  _ => null,
};

/// `contains` and `doesnt_contain`: see [Rules.contains].
final class ArrayValuesRule extends Rule {
  /// The rule [name] over [values].
  const ArrayValuesRule(this.name, this.values);
  @override
  final String name;

  /// The values looked for.
  final List<String> values;

  // `contains` names nothing; `doesnt_contain` uses replaceIn.
  @override
  Map<String, Object?> get parameters => {'values': values.join(', ')};

  @override
  String? passes(ValidationContext c) {
    final items = _arrayValues(c.value);
    if (items == null) {
      return name;
    }
    final ok = name == 'contains'
        ? values.every((v) => items.any((item) => _looselyEquals(item, v)))
        // `in_array(..., true)`: a parameter is a string, so only an equal
        // string matches.
        : values.every(
            (v) => !items.any((item) => item is String && item == v),
          );
    return ok ? null : name;
  }
}

/// `doesnt_start_with` and `doesnt_end_with`: see [Rules.doesntStartWith].
final class DoesntAffixRule extends Rule {
  /// The rule [name] over [affixes].
  const DoesntAffixRule(this.name, this.affixes);
  @override
  final String name;

  /// The prefixes (or suffixes) refused.
  final List<String> affixes;

  @override
  Map<String, Object?> get parameters => {'values': affixes.join(', ')};

  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    // `is_string($value) || is_numeric($value)`.
    final text = switch (value) {
      String() => value,
      // PHP's (string) of a whole float has no ".0": JSON 1.0 is "1".
      double() when value.isFinite && value == value.truncateToDouble() =>
        '${value.toInt()}',
      num() => '$value',
      _ => null,
    };
    if (text == null) {
      return name;
    }
    // `Str::startsWith` ignores an empty needle.
    bool hit(String a) =>
        a.isNotEmpty &&
        (name == 'doesnt_start_with' ? text.startsWith(a) : text.endsWith(a));
    return affixes.any(hit) ? name : null;
  }
}

/// `in_array`: see [Rules.inArray].
final class InArrayRule extends Rule {
  /// One of the values at [other].
  const InArrayRule(this.other);

  /// The path of the values, with `*` (`items.*.id`).
  final String other;
  @override
  String get name => 'in_array';

  // `replaceInArray`: the parameter as written, not resolved (`in_array` is
  // not one of Laravel's dependent rules).
  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'other': context.attributeNames[other] ?? other.replaceAll('_', ' '),
  };

  @override
  String? passes(ValidationContext c) {
    // `Arr::dot` of the data, keys matched by `Str::is` (`*` is any text).
    final pattern = RegExp(
      '^${other.split('*').map(RegExp.escape).join('.*')}\$',
    );
    final values = <Object?>[];
    void walk(Object? node, String path) {
      switch (node) {
        case Map<Object?, Object?>() when node.isNotEmpty:
          for (final MapEntry(:key, :value) in node.entries) {
            walk(value, path.isEmpty ? '$key' : '$path.$key');
          }
        case List<Object?>() when node.isNotEmpty:
          for (var i = 0; i < node.length; i++) {
            walk(node[i], path.isEmpty ? '$i' : '$path.$i');
          }
        default:
          if (pattern.hasMatch(path)) {
            values.add(node);
          }
      }
    }

    walk(c.data, '');
    return values.contains(c.value) ? null : name;
  }
}

/// `in_array_keys` and `array_keys`: see [Rules.inArrayKeys].
final class ArrayKeysRule extends Rule {
  /// The rule [name] over [keys].
  const ArrayKeysRule(this.name, this.keys);
  @override
  final String name;

  /// The keys looked for (`in_array_keys`) or allowed (`array_keys`).
  final List<String> keys;

  /// The keys of an array value; list indexes as their decimal text.
  static List<String>? _keysOf(Object? value) => switch (value) {
    Map<Object?, Object?>() => [for (final k in value.keys) '$k'],
    List<Object?>() => [for (var i = 0; i < value.length; i++) '$i'],
    _ => null,
  };

  // `replaceArrayKeys` also fills `:unexpected`, the keys that are not
  // allowed.
  @override
  Map<String, Object?> parametersFor(ValidationContext context) => {
    'values': keys.join(', '),
    if (name == 'array_keys')
      'unexpected': [
        for (final k in _keysOf(context.value) ?? const <String>[])
          if (!keys.contains(k)) k,
      ].join(', '),
  };

  @override
  String? passes(ValidationContext c) {
    final present = _keysOf(c.value);
    if (present == null || (name == 'in_array_keys' && keys.isEmpty)) {
      return name;
    }
    final ok = name == 'in_array_keys'
        ? keys.any(present.contains)
        : present.every(keys.contains);
    return ok ? null : name;
  }
}

/// `hex_color`: see [Rules.hexColor].
final class HexColorRule extends Rule {
  /// The hex color rule; use [Rules.hexColor].
  const HexColorRule();
  @override
  String get name => 'hex_color';

  static final RegExp _pattern = RegExp(
    r'^#(?:(?:[0-9a-f]{3}){1,2}|(?:[0-9a-f]{4}){1,2})$',
    caseSensitive: false,
  );

  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && _pattern.hasMatch(value) ? null : name;
  }
}

/// `mac_address`: see [Rules.macAddress].
final class MacAddressRule extends Rule {
  /// The MAC address rule; use [Rules.macAddress].
  const MacAddressRule();
  @override
  String get name => 'mac_address';

  static final RegExp _pattern = RegExp(
    r'^(?:[0-9a-f]{2}(?::[0-9a-f]{2}){5}|[0-9a-f]{2}(?:-[0-9a-f]{2}){5}|'
    r'[0-9a-f]{4}(?:\.[0-9a-f]{4}){2})$',
    caseSensitive: false,
  );

  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    return value is String && _pattern.hasMatch(value) ? null : name;
  }
}

/// `encoding`: see [Rules.encoding].
final class EncodingRule extends Rule {
  /// Valid in [encoding], checked when the rule runs (as Laravel does): a
  /// name that is not an encoding is an [ArgumentError] (Laravel's
  /// InvalidArgumentException); an encoding PHP knows but Daravel does not
  /// check yet is an [UnsupportedError]. `invalid_validation_rule` flags
  /// both in rule strings before they run.
  const EncodingRule(this.encoding);

  /// The encoding name, as written.
  final String encoding;

  /// The encodings Daravel checks, normalized.
  static const Set<String> supported = {'utf8', 'ascii', 'iso88591', 'latin1'};

  /// Common names of PHP's `mb_list_encodings()` (mbstring) that Daravel
  /// does not check yet, normalized: a rule naming one is valid in Laravel.
  static const Set<String> knownToPhp = {
    'utf16',
    'utf16be',
    'utf16le',
    'utf32',
    'utf32be',
    'utf32le',
    'ucs2',
    'ucs2be',
    'ucs2le',
    'ucs4',
    'ucs4be',
    'ucs4le',
    'utf7',
    'utf7imap',
    'windows1252',
    'cp1252',
    'windows1251',
    'cp1251',
    'windows1254',
    'iso88592',
    'iso88593',
    'iso88594',
    'iso88595',
    'iso88596',
    'iso88597',
    'iso88598',
    'iso88599',
    'iso885910',
    'iso885913',
    'iso885914',
    'iso885915',
    'iso885916',
    'sjis',
    'shiftjis',
    'eucjp',
    'jis',
    'iso2022jp',
    'euckr',
    'big5',
    'gb18030',
    'cp936',
    'euccn',
    'koi8r',
    'koi8u',
    'cp866',
    '7bit',
    '8bit',
  };

  /// [name] without case and punctuation (`UTF-8` and `utf8` match).
  static String normalized(String name) =>
      name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  @override
  String get name => 'encoding';
  @override
  Map<String, Object?> get parameters => {'encoding': encoding};

  @override
  String? passes(ValidationContext c) {
    final key = normalized(encoding);
    if (knownToPhp.contains(key)) {
      throw UnsupportedError(
        'Validation rule encoding [$encoding] is not supported by Daravel '
        'yet; supported: UTF-8, ASCII, ISO-8859-1',
      );
    }
    if (!supported.contains(key)) {
      throw ArgumentError.value(
        encoding,
        'encoding',
        'Validation rule encoding parameter [$encoding] is not a valid '
            'encoding',
      );
    }
    final value = c.value;
    final List<int> units;
    final bool bytes;
    switch (value) {
      case UploadedFile():
        units = value.readAsBytesSync();
        bytes = true;
      case String():
        units = value.codeUnits;
        bytes = false;
      default:
        return name;
    }
    final ok = switch (key) {
      'ascii' => units.every((u) => u < 0x80),
      // mb_check_encoding looks at bytes, and every byte sequence is valid
      // ISO-8859-1: a string (sent as UTF-8 bytes) always passes in Laravel.
      'iso88591' || 'latin1' => true,
      _ => bytes ? _utf8(units) : _wellFormed(units),
    };
    return ok ? null : name;
  }

  static bool _utf8(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// UTF-16 code units with no lone surrogate: text UTF-8 can hold.
  static bool _wellFormed(List<int> units) {
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      if (u >= 0xD800 && u <= 0xDBFF) {
        final next = i + 1 < units.length ? units[i + 1] : 0;
        if (next < 0xDC00 || next > 0xDFFF) {
          return false;
        }
        i++;
      } else if (u >= 0xDC00 && u <= 0xDFFF) {
        return false;
      }
    }
    return true;
  }
}

/// `base64`: see [Rules.base64].
final class Base64Rule extends Rule {
  /// The Base64 rule; use [Rules.base64].
  const Base64Rule();
  @override
  String get name => 'base64';

  @override
  String? passes(ValidationContext c) {
    final value = c.value;
    if (value is! String || value.isEmpty) {
      return name;
    }
    try {
      // `base64_decode($value, true)` then `base64_encode` back: only the
      // canonical standard alphabet with padding passes.
      return base64Encode(base64Decode(value)) == value ? null : name;
    } on FormatException {
      return name;
    }
  }
}
