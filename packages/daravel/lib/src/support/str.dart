import 'dart:convert';
import 'dart:math';

import '../database/orm/keys.dart';

/// String helpers with Laravel's `Str` semantics (BLUEPRINT_V2 §7.12).
///
/// ```dart
/// Str.slug('Hello World!');          // hello-world
/// Str.snake('emailVerifiedAt');      // email_verified_at
/// Str.studly('user_profile');        // UserProfile
/// Str.plural('category');            // categories
/// Str.limit('The quick brown fox', 9); // The quick...
/// ```
abstract final class Str {
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _wordSeparators = RegExp(r'[\s_-]+');

  // -- Case ------------------------------------------------------------------

  /// `fooBar` / `Foo Bar` → `foo_bar` (Laravel `Str::snake`).
  static String snake(String value, [String delimiter = '_']) {
    if (value.toLowerCase() == value) {
      return value;
    }
    final joined = ucwords(value).replaceAll(_whitespace, '');
    final separated = joined.replaceAllMapped(
      RegExp(r'(.)(?=[A-Z])'),
      (m) => '${m[1]}$delimiter',
    );
    return separated.toLowerCase();
  }

  /// `foo_bar` / `foo-bar` / `foo bar` → `FooBar`.
  static String studly(String value) => value
      .split(_wordSeparators)
      .where((w) => w.isNotEmpty)
      .map(ucfirst)
      .join();

  /// `foo_bar` → `fooBar`.
  static String camel(String value) => lcfirst(studly(value));

  /// `fooBar` → `foo-bar`.
  static String kebab(String value) => snake(value, '-');

  /// `hello world` → `Hello World`.
  static String title(String value) => value.toLowerCase().splitMapJoin(
    RegExp(r'[^\s\-_]+'),
    onMatch: (m) => ucfirst(m[0]!),
    onNonMatch: (s) => s,
  );

  /// `emailNotificationSent` / `email_notification_sent` → `Email
  /// Notification Sent`.
  static String headline(String value) {
    final parts = value.contains(_wordSeparators)
        ? value.split(_wordSeparators)
        : [value];
    return parts
        .expand(
          (part) => part
              .replaceAllMapped(
                RegExp(r'([a-z0-9])([A-Z])'),
                (m) => '${m[1]} ${m[2]}',
              )
              .split(' '),
        )
        .where((w) => w.isNotEmpty)
        .map((w) => ucfirst(w.toLowerCase()))
        .join(' ');
  }

  /// URL slug: lower case ASCII, separators collapsed, `@` → `at`.
  static String slug(String value, {String separator = '-'}) {
    final flip = separator == '-' ? '_' : '-';
    var result = ascii(value)
        .replaceAll(flip, separator)
        .replaceAll('@', '${separator}at$separator')
        .toLowerCase();
    result = result.replaceAll(
      RegExp('[^${RegExp.escape(separator)}a-z0-9\\s]'),
      '',
    );
    result = result.replaceAll(
      RegExp('[${RegExp.escape(separator)}\\s]+'),
      separator,
    );
    return trimChars(result, separator);
  }

  static String ucfirst(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static String lcfirst(String value) =>
      value.isEmpty ? value : value[0].toLowerCase() + value.substring(1);

  /// Upper-cases the first letter of every whitespace separated word.
  static String ucwords(String value) => value.splitMapJoin(
    RegExp(r'\S+'),
    onMatch: (m) => ucfirst(m[0]!),
    onNonMatch: (s) => s,
  );

  // -- Slicing ---------------------------------------------------------------

  static String after(String subject, String search) {
    final index = search.isEmpty ? -1 : subject.indexOf(search);
    return index == -1 ? subject : subject.substring(index + search.length);
  }

  static String afterLast(String subject, String search) {
    final index = search.isEmpty ? -1 : subject.lastIndexOf(search);
    return index == -1 ? subject : subject.substring(index + search.length);
  }

  static String before(String subject, String search) {
    final index = search.isEmpty ? -1 : subject.indexOf(search);
    return index == -1 ? subject : subject.substring(0, index);
  }

  static String beforeLast(String subject, String search) {
    final index = search.isEmpty ? -1 : subject.lastIndexOf(search);
    return index == -1 ? subject : subject.substring(0, index);
  }

  /// The part between the first [from] and the last [to].
  static String between(String subject, String from, String to) =>
      from.isEmpty || to.isEmpty
      ? subject
      : beforeLast(after(subject, from), to);

  /// Truncates to [limit] characters plus [end] (`Str::limit`).
  static String limit(String value, [int limit = 100, String end = '...']) =>
      value.length <= limit
      ? value
      : '${value.substring(0, limit).trimRight()}$end';

  /// Keeps the first [count] words plus [end] (`Str::words`).
  static String words(String value, [int count = 100, String end = '...']) {
    final matches = RegExp(r'\S+').allMatches(value).toList();
    if (matches.length <= count) {
      return value;
    }
    return '${value.substring(0, matches[count - 1].end)}$end';
  }

  /// Replaces [length] characters from [index] with [character]
  /// (`Str::mask('taylor@example.com', '*', 3)`). Negative [index] counts
  /// from the end.
  static String mask(String value, String character, int index, [int? length]) {
    if (character.isEmpty) {
      return value;
    }
    final start = index < 0 ? max(0, value.length + index) : index;
    if (start >= value.length) {
      return value;
    }
    final end = length == null
        ? value.length
        : min(
            value.length,
            length < 0 ? value.length + length : start + length,
          );
    if (end <= start) {
      return value;
    }
    return value.substring(0, start) +
        character[0] * (end - start) +
        value.substring(end);
  }

  /// Trims and collapses inner whitespace (`Str::squish`).
  static String squish(String value) =>
      value.trim().replaceAll(_whitespace, ' ');

  /// Prefixes [prefix] unless already there (`Str::start`).
  static String start(String value, String prefix) =>
      value.startsWith(prefix) ? value : '$prefix$value';

  /// Suffixes [cap] unless already there (`Str::finish`).
  static String finish(String value, String cap) =>
      value.endsWith(cap) ? value : '$value$cap';

  static String replaceFirst(String search, String replace, String subject) =>
      search.isEmpty ? subject : subject.replaceFirst(search, replace);

  static String replaceLast(String search, String replace, String subject) {
    final index = search.isEmpty ? -1 : subject.lastIndexOf(search);
    return index == -1
        ? subject
        : subject.replaceRange(index, index + search.length, replace);
  }

  static String padBoth(String value, int length, [String pad = ' ']) {
    final missing = length - value.length;
    if (missing <= 0 || pad.isEmpty) {
      return value;
    }
    final left = missing ~/ 2;
    return _repeat(pad, left) + value + _repeat(pad, missing - left);
  }

  static String padLeft(String value, int length, [String pad = ' ']) {
    final missing = length - value.length;
    return missing <= 0 || pad.isEmpty ? value : _repeat(pad, missing) + value;
  }

  static String padRight(String value, int length, [String pad = ' ']) {
    final missing = length - value.length;
    return missing <= 0 || pad.isEmpty ? value : value + _repeat(pad, missing);
  }

  static String _repeat(String pad, int length) =>
      (pad * (length ~/ pad.length + 1)).substring(0, length);

  static int wordCount(String value) => RegExp(r'\S+').allMatches(value).length;

  static String trimChars(String value, String chars) {
    if (chars.isEmpty) {
      return value;
    }
    final pattern = RegExp(
      '^[${RegExp.escape(chars)}]+|[${RegExp.escape(chars)}]+\$',
    );
    return value.replaceAll(pattern, '');
  }

  // -- Predicates ------------------------------------------------------------

  /// Whether [haystack] contains any of [needles] (a `String` or an
  /// `Iterable<String>`).
  static bool contains(
    String haystack,
    Object needles, {
    bool ignoreCase = false,
  }) {
    final subject = ignoreCase ? haystack.toLowerCase() : haystack;
    return _needles(needles).any(
      (n) => n.isNotEmpty && subject.contains(ignoreCase ? n.toLowerCase() : n),
    );
  }

  /// Whether [haystack] contains every needle.
  static bool containsAll(
    String haystack,
    Iterable<String> needles, {
    bool ignoreCase = false,
  }) => needles.every((n) => contains(haystack, n, ignoreCase: ignoreCase));

  static bool startsWith(String haystack, Object needles) =>
      _needles(needles).any((n) => n.isNotEmpty && haystack.startsWith(n));

  static bool endsWith(String haystack, Object needles) =>
      _needles(needles).any((n) => n.isNotEmpty && haystack.endsWith(n));

  static Iterable<String> _needles(Object needles) => switch (needles) {
    final String single => [single],
    final Iterable<Object?> many => many.whereType<String>(),
    _ => throw ArgumentError.value(needles, 'needles', 'String or Iterable'),
  };

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final RegExp _ulid = RegExp(
    r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$',
    caseSensitive: false,
  );

  static bool isUuid(String value) => _uuid.hasMatch(value);

  static bool isUlid(String value) => _ulid.hasMatch(value);

  static bool isAscii(String value) => value.codeUnits.every((c) => c < 0x80);

  static bool isJson(String value) {
    try {
      jsonDecode(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  // -- Generators ------------------------------------------------------------

  static final Random _random = Random.secure();
  static const String _alphanumeric =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// Cryptographically secure alphanumeric string (`Str::random`).
  static String random([int length = 16]) => String.fromCharCodes([
    for (var i = 0; i < length; i++)
      _alphanumeric.codeUnitAt(_random.nextInt(_alphanumeric.length)),
  ]);

  /// Random UUID v4.
  static String uuid() => KeyGenerator.uuid();

  /// Sortable ULID (26 Crockford base32 characters).
  static String ulid([DateTime? time]) => KeyGenerator.ulid(time);

  // -- Transliteration ---------------------------------------------------------

  static const Map<String, String> _ascii = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'æ': 'ae',
    'ç': 'c',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ø': 'o',
    'œ': 'oe',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ß': 'ss',
    'À': 'A',
    'Á': 'A',
    'Â': 'A',
    'Ã': 'A',
    'Ä': 'A',
    'Å': 'A',
    'Æ': 'AE',
    'Ç': 'C',
    'È': 'E',
    'É': 'E',
    'Ê': 'E',
    'Ë': 'E',
    'Ì': 'I',
    'Í': 'I',
    'Î': 'I',
    'Ï': 'I',
    'Ñ': 'N',
    'Ò': 'O',
    'Ó': 'O',
    'Ô': 'O',
    'Õ': 'O',
    'Ö': 'O',
    'Ø': 'O',
    'Œ': 'OE',
    'Ù': 'U',
    'Ú': 'U',
    'Û': 'U',
    'Ü': 'U',
    'Ý': 'Y',
  };

  /// Replaces common Latin accented letters with ASCII (`Str::ascii`, for
  /// Latin scripts; other characters are kept).
  static String ascii(String value) {
    if (isAscii(value)) {
      return value;
    }
    final out = StringBuffer();
    for (final char in value.split('')) {
      out.write(_ascii[char] ?? char);
    }
    return out.toString();
  }

  // -- Pluralization (English) ---------------------------------------------------

  static const Map<String, String> _irregular = {
    'person': 'people',
    'man': 'men',
    'woman': 'women',
    'child': 'children',
    'tooth': 'teeth',
    'foot': 'feet',
    'mouse': 'mice',
    'goose': 'geese',
    'ox': 'oxen',
    'leaf': 'leaves',
    'life': 'lives',
    'knife': 'knives',
    'wife': 'wives',
    'half': 'halves',
    'wolf': 'wolves',
    'shelf': 'shelves',
    'criterion': 'criteria',
    'datum': 'data',
    'medium': 'media',
    'analysis': 'analyses',
    'crisis': 'crises',
    'thesis': 'theses',
    'quiz': 'quizzes',
    'status': 'statuses',
    'alias': 'aliases',
    'bus': 'buses',
    'hero': 'heroes',
    'potato': 'potatoes',
    'tomato': 'tomatoes',
    'cactus': 'cacti',
    'index': 'indices',
    'matrix': 'matrices',
    'vertex': 'vertices',
  };

  static const Set<String> _uncountable = {
    'audio',
    'education',
    'equipment',
    'feedback',
    'fish',
    'furniture',
    'information',
    'knowledge',
    'metadata',
    'money',
    'news',
    'police',
    'rice',
    'series',
    'sheep',
    'species',
    'traffic',
    'deer',
    'moose',
    'software',
    'hardware',
    'luggage',
    'advice',
    'evidence',
    'research',
  };

  static final Map<String, String> _singularIrregular = {
    for (final entry in _irregular.entries) entry.value: entry.key,
  };

  /// English plural of [value] (singular when [count] is 1), keeping its
  /// case (`Str::plural`).
  static String plural(String value, [num count = 2]) {
    if (count == 1 || value.isEmpty) {
      return value;
    }
    return _matchCase(_inflect(value, _pluralOf), value);
  }

  /// English singular of [value] (`Str::singular`).
  static String singular(String value) =>
      value.isEmpty ? value : _matchCase(_inflect(value, _singularOf), value);

  /// `UserProfile` → `UserProfiles`: pluralizes the last studly word.
  static String pluralStudly(String value, [num count = 2]) {
    final parts = RegExp(r'[A-Z][^A-Z]*|^[^A-Z]+').allMatches(value);
    if (parts.isEmpty) {
      return plural(value, count);
    }
    final last = parts.last;
    return value.substring(0, last.start) + plural(last[0]!, count);
  }

  /// Applies [rule] to the last word of [value] (`blog_post` → `blog_posts`).
  static String _inflect(String value, String Function(String) rule) {
    final match = RegExp(r'([A-Za-z]+)$').firstMatch(value);
    if (match == null) {
      return value;
    }
    return value.substring(0, match.start) + rule(match[1]!);
  }

  static String _pluralOf(String word) {
    final lower = word.toLowerCase();
    if (_uncountable.contains(lower) || _singularIrregular.containsKey(lower)) {
      return word;
    }
    final irregular = _irregular[lower];
    if (irregular != null) {
      return irregular;
    }
    if (RegExp(r'[^aeiou]y$').hasMatch(lower)) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    if (RegExp(r'(s|x|z|ch|sh)$').hasMatch(lower)) {
      return '${word}es';
    }
    return '${word}s';
  }

  static String _singularOf(String word) {
    final lower = word.toLowerCase();
    if (_uncountable.contains(lower) || _irregular.containsKey(lower)) {
      return word;
    }
    final irregular = _singularIrregular[lower];
    if (irregular != null) {
      return irregular;
    }
    if (lower.endsWith('ies') && lower.length > 3) {
      return '${word.substring(0, word.length - 3)}y';
    }
    if (RegExp(r'(ss|x|z|ch|sh|ses)es$').hasMatch(lower) ||
        RegExp(r'(x|z|ch|sh)es$').hasMatch(lower)) {
      return word.substring(0, word.length - 2);
    }
    if (lower.endsWith('sses')) {
      return word.substring(0, word.length - 2);
    }
    if (lower.endsWith('s') &&
        !lower.endsWith('ss') &&
        !lower.endsWith('us') &&
        !lower.endsWith('is')) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  static String _matchCase(String value, String comparison) {
    if (comparison == comparison.toUpperCase() &&
        comparison != comparison.toLowerCase()) {
      return value.toUpperCase();
    }
    if (comparison.isNotEmpty &&
        comparison[0] == comparison[0].toUpperCase() &&
        comparison[0] != comparison[0].toLowerCase()) {
      return ucfirst(value);
    }
    return value;
  }
}
