import 'helpers.dart';
import 'str.dart';

/// `Str` as methods on the string (Laravel's `Str::of()` chain):
/// `rawTitle.after(':').squish().slug()`. Members that `String` already
/// has (`contains`, `startsWith`, `padLeft`, …) keep their Dart meaning;
/// use `Str` for Laravel's versions of those.
extension DaravelString on String {
  /// `snake_case`, as [Str.snake].
  String snake([String delimiter = '_']) => Str.snake(this, delimiter);

  /// `camelCase`, as [Str.camel].
  String camel() => Str.camel(this);

  /// `StudlyCase`, as [Str.studly].
  String studly() => Str.studly(this);

  /// `kebab-case`, as [Str.kebab].
  String kebab() => Str.kebab(this);

  /// Title Case, as [Str.title].
  String title() => Str.title(this);

  /// Headline Case from any casing, as [Str.headline].
  String headline() => Str.headline(this);

  /// A URL slug, as [Str.slug].
  String slug({String separator = '-'}) => Str.slug(this, separator: separator);

  /// First character upper case, as [Str.ucfirst].
  String ucfirst() => Str.ucfirst(this);

  /// First character lower case, as [Str.lcfirst].
  String lcfirst() => Str.lcfirst(this);

  /// Every word capitalized, as [Str.ucwords].
  String ucwords() => Str.ucwords(this);

  /// The plural, unless [count] is 1, as [Str.plural].
  String plural([num count = 2]) => Str.plural(this, count);

  /// The singular, as [Str.singular].
  String singular() => Str.singular(this);

  /// The plural of the last word of a StudlyCase string.
  String pluralStudly([num count = 2]) => Str.pluralStudly(this, count);

  /// Transliterated to ASCII, as [Str.ascii].
  String ascii() => Str.ascii(this);

  /// What follows the first [search].
  String after(String search) => Str.after(this, search);

  /// What follows the last [search].
  String afterLast(String search) => Str.afterLast(this, search);

  /// What precedes the first [search].
  String before(String search) => Str.before(this, search);

  /// What precedes the last [search].
  String beforeLast(String search) => Str.beforeLast(this, search);

  /// What lies between [from] and [to].
  String between(String from, String to) => Str.between(this, from, to);

  /// Cut to [limit] characters, followed by [end].
  String limit([int limit = 100, String end = '...']) =>
      Str.limit(this, limit, end);

  /// Cut to [count] words, followed by [end].
  String words([int count = 100, String end = '...']) =>
      Str.words(this, count, end);

  /// Masks [length] characters from [index] with [character].
  String mask(String character, int index, [int? length]) =>
      Str.mask(this, character, index, length);

  /// Whitespace collapsed to single spaces and trimmed.
  String squish() => Str.squish(this);

  /// Starts with [prefix] once.
  String start(String prefix) => Str.start(this, prefix);

  /// Ends with [cap] once.
  String finish(String cap) => Str.finish(this, cap);

  /// Without the characters of [chars] at either end.
  String trimChars(String chars) => Str.trimChars(this, chars);

  /// The number of words.
  int get wordCount => Str.wordCount(this);

  /// Whether it is a UUID.
  bool get isUuid => Str.isUuid(this);

  /// Whether it is a ULID.
  bool get isUlid => Str.isUlid(this);

  /// Whether it is 7-bit ASCII only.
  bool get isAscii => Str.isAscii(this);

  /// Whether it is valid JSON.
  bool get isJson => Str.isJson(this);

  /// Whether it contains every one of [needles].
  bool containsAll(Iterable<String> needles, {bool ignoreCase = false}) =>
      Str.containsAll(this, needles, ignoreCase: ignoreCase);
}

/// Blank checks on possibly-null strings (`blank()` / `filled()`).
extension DaravelNullableString on String? {
  /// Whether it is null, empty or whitespace (`blank()`).
  bool get isBlank => blank(this);

  /// Whether it holds more than whitespace (`filled()`).
  bool get isFilled => filled(this);

  /// The string, or `''` when null.
  String get orEmpty => this ?? '';

  /// The string, or null when blank.
  String? get nullIfBlank => blank(this) ? null : this;
}
