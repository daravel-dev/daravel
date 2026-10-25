import 'helpers.dart';
import 'str.dart';

/// `Str` as methods on the string (Laravel's `Str::of()` chain):
/// `rawTitle.after(':').squish().slug()`. Members that `String` already
/// has (`contains`, `startsWith`, `padLeft`, …) keep their Dart meaning;
/// use `Str` for Laravel's versions of those.
extension DaravelString on String {
  String snake([String delimiter = '_']) => Str.snake(this, delimiter);
  String camel() => Str.camel(this);
  String studly() => Str.studly(this);
  String kebab() => Str.kebab(this);
  String title() => Str.title(this);
  String headline() => Str.headline(this);
  String slug({String separator = '-'}) => Str.slug(this, separator: separator);
  String ucfirst() => Str.ucfirst(this);
  String lcfirst() => Str.lcfirst(this);
  String ucwords() => Str.ucwords(this);
  String plural([num count = 2]) => Str.plural(this, count);
  String singular() => Str.singular(this);
  String pluralStudly([num count = 2]) => Str.pluralStudly(this, count);
  String ascii() => Str.ascii(this);

  String after(String search) => Str.after(this, search);
  String afterLast(String search) => Str.afterLast(this, search);
  String before(String search) => Str.before(this, search);
  String beforeLast(String search) => Str.beforeLast(this, search);
  String between(String from, String to) => Str.between(this, from, to);
  String limit([int limit = 100, String end = '...']) =>
      Str.limit(this, limit, end);
  String words([int count = 100, String end = '...']) =>
      Str.words(this, count, end);
  String mask(String character, int index, [int? length]) =>
      Str.mask(this, character, index, length);
  String squish() => Str.squish(this);
  String start(String prefix) => Str.start(this, prefix);
  String finish(String cap) => Str.finish(this, cap);
  String trimChars(String chars) => Str.trimChars(this, chars);
  int get wordCount => Str.wordCount(this);

  bool get isUuid => Str.isUuid(this);
  bool get isUlid => Str.isUlid(this);
  bool get isAscii => Str.isAscii(this);
  bool get isJson => Str.isJson(this);
  bool containsAll(Iterable<String> needles, {bool ignoreCase = false}) =>
      Str.containsAll(this, needles, ignoreCase: ignoreCase);
}

/// Blank checks on possibly-null strings (`blank()` / `filled()`).
extension DaravelNullableString on String? {
  bool get isBlank => blank(this);
  bool get isFilled => filled(this);
  String get orEmpty => this ?? '';
  String? get nullIfBlank => blank(this) ? null : this;
}
