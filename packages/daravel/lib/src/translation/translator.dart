import '../foundation/container.dart';
import '../foundation/locale.dart';
import 'plural_rules.g.dart';

/// Translations (Laravel's `Translator`, `__()`, `trans()` and
/// `trans_choice()`).
///
/// Two kinds of lines, as in Laravel:
///
/// * keyed lines (`'auth.failed'`) registered with [addLines] or
///   `ApplicationBuilder.withTranslations`, looked up in the locale and then
///   in the [fallback] locale;
/// * JSON lines (`lang/<locale>.json`, keyed by the text itself) added with
///   [addJson], looked up in the locale only.
///
/// A missing key returns the key. Placeholders are replaced as Laravel does
/// (`:name`, `:Name` capitalised, `:NAME` upper-cased, longest first, in one
/// pass) and plural lines (`'{0} none|{1} one|[2,*] :count'`) use Laravel's
/// selector and plural rules for 280 locales.
final class Translator implements TranslationLines {
  Translator({this.fallback = 'en'});

  /// The locale keyed lines fall back to (`APP_FALLBACK_LOCALE`).
  String fallback;

  final Map<String, Map<String, String>> _lines = {};
  final Map<String, Map<String, String>> _json = {};

  /// Adds keyed lines for [locale]; nested maps become dotted keys
  /// (`{'auth': {'failed': '...'}}` is `auth.failed`).
  void addLines(Map<String, Object?> lines, String locale) {
    final target = _lines.putIfAbsent(locale, () => {});
    void walk(Map<String, Object?> map, String prefix) {
      for (final MapEntry(:key, :value) in map.entries) {
        final name = prefix.isEmpty ? key : '$prefix.$key';
        switch (value) {
          case final Map<String, Object?> nested:
            walk(nested, name);
          case null:
            break;
          default:
            target[name] = '$value';
        }
      }
    }

    walk(lines, '');
  }

  /// Adds JSON lines (`lang/<locale>.json`) for [locale].
  void addJson(Map<String, Object?> lines, String locale) {
    final target = _json.putIfAbsent(locale, () => {});
    for (final MapEntry(:key, :value) in lines.entries) {
      if (value != null) {
        target[key] = '$value';
      }
    }
  }

  /// Keyed lines by locale (read-only).
  Map<String, Map<String, String>> get lines => {
    for (final MapEntry(:key, :value) in _lines.entries)
      key: Map.unmodifiable(value),
  };

  /// JSON lines by locale (read-only).
  Map<String, Map<String, String>> get jsonLines => {
    for (final MapEntry(:key, :value) in _json.entries)
      key: Map.unmodifiable(value),
  };

  /// The locales that have lines.
  Set<String> get locales => {..._lines.keys, ..._json.keys};

  String? _line(String key, String locale, {required bool fallback}) {
    final line = _json[locale]?[key] ?? _lines[locale]?[key];
    if (line != null || !fallback || locale == this.fallback) {
      return line;
    }
    return _lines[this.fallback]?[key];
  }

  @override
  String? line(String key, {String? locale, bool fallback = true}) =>
      _line(key, locale ?? currentLocale(), fallback: fallback);

  /// Whether [key] has a line in [locale] (the current one by default).
  bool has(String key, {String? locale, bool fallback = true}) =>
      _line(key, locale ?? currentLocale(), fallback: fallback) != null;

  /// The line for [key] with [replace] applied, or [key] itself.
  String get(
    String key, {
    Map<String, Object?> replace = const {},
    String? locale,
    bool fallback = true,
  }) => makeReplacements(
    _line(key, locale ?? currentLocale(), fallback: fallback) ?? key,
    replace,
  );

  /// The plural form of [key] for [count] (`:count` is replaced unless
  /// [replace] has it).
  String choice(
    String key,
    num count, {
    Map<String, Object?> replace = const {},
    String? locale,
  }) {
    final wanted = locale ?? currentLocale();
    // Laravel's localeForChoice: the plural rules of the locale the line
    // comes from.
    final source = _line(key, wanted, fallback: false) != null
        ? wanted
        : fallback;
    final line = _line(key, wanted, fallback: true) ?? key;
    return makeReplacements(choose(line, count, source), {
      'count': count,
      ...replace,
    });
  }

  /// Laravel's `makeReplacements`: `:key`, `:Key` and `:KEY` for each entry,
  /// longest placeholder first, in a single pass (PHP's `strtr`).
  static String makeReplacements(String line, Map<String, Object?> replace) {
    if (replace.isEmpty) {
      return line;
    }
    final table = <String, String>{};
    for (final MapEntry(:key, :value) in replace.entries) {
      final text = value?.toString() ?? '';
      table[':${_ucfirst(key)}'] = _ucfirst(text);
      table[':${key.toUpperCase()}'] = text.toUpperCase();
      table[':$key'] = text;
    }
    final keys = table.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final out = StringBuffer();
    var i = 0;
    outer:
    while (i < line.length) {
      if (line.codeUnitAt(i) == 0x3A) {
        for (final placeholder in keys) {
          if (line.startsWith(placeholder, i)) {
            out.write(table[placeholder]);
            i += placeholder.length;
            continue outer;
          }
        }
      }
      out.writeCharCode(line.codeUnitAt(i));
      i++;
    }
    return out.toString();
  }

  static String _ucfirst(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  static final RegExp _condition = RegExp(
    r'^[\{\[]([-?\d|*,\.*]*)[\}\]](.*)$',
    dotAll: true,
  );

  /// Laravel's `MessageSelector::choose`: an explicit `{n}` or `[a,b]`
  /// (`*` for open ends) segment matching [number] wins; otherwise the
  /// segment at the locale's plural index, or the first.
  static String choose(String line, num number, String locale) {
    final segments = line.split('|');
    for (final segment in segments) {
      final match = _condition.firstMatch(segment);
      if (match == null) {
        continue;
      }
      final condition = match[1]!;
      final value = match[2]!;
      if (condition.contains(',')) {
        final comma = condition.indexOf(',');
        final from = condition.substring(0, comma);
        final to = condition.substring(comma + 1);
        final low = _num(from);
        final high = _num(to);
        final inRange = to == '*'
            ? low != null && number >= low
            : from == '*'
            ? high != null && number <= high
            : low != null && high != null && number >= low && number <= high;
        if (inRange) {
          return value.trim();
        }
      }
      if (_num(condition) == number) {
        return value.trim();
      }
    }
    final stripped = [
      for (final segment in segments)
        segment.replaceFirst(RegExp(r'^[\{\[][-?\d|*,\.*]*[\}\]]'), ''),
    ];
    final index = pluralIndex(locale, number);
    return stripped.length == 1 || index >= stripped.length
        ? stripped.first
        : stripped[index];
  }

  static num? _num(String text) => num.tryParse(text.trim());
}

Translator? _translator() {
  try {
    return Container.current.tryMake<Translator>();
  } on StateError {
    return null;
  }
}

/// Outside an application (plain Dart, tests without `boot`).
final Translator _standalone = Translator();

Translator _active() => _translator() ?? _standalone;

/// Laravel's `__()` and `trans()` (a leading underscore makes a Dart name
/// private, so there is no `__`): the line for [key] in the current locale
/// with [replace] applied, or [key] itself.
String trans(
  String key, [
  Map<String, Object?> replace = const {},
  String? locale,
]) => _active().get(key, replace: replace, locale: locale);

/// Laravel's `trans_choice()`: the plural form of [key] for [count].
String transChoice(
  String key,
  num count, [
  Map<String, Object?> replace = const {},
  String? locale,
]) => _active().choice(key, count, replace: replace, locale: locale);

/// Laravel's `Lang` facade over the application's [Translator].
abstract final class Lang {
  static Translator get translator => _active();

  static String get(
    String key, [
    Map<String, Object?> replace = const {},
    String? locale,
  ]) => _active().get(key, replace: replace, locale: locale);

  static String choice(
    String key,
    num count, [
    Map<String, Object?> replace = const {},
    String? locale,
  ]) => _active().choice(key, count, replace: replace, locale: locale);

  static bool has(String key, [String? locale]) =>
      _active().has(key, locale: locale);

  static String get locale => currentLocale();

  static void setLocale(String locale) => setCurrentLocale(locale);
}
