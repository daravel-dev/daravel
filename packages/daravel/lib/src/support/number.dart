/// Laravel's `Illuminate\Support\Number` for the `en` and `id` locales,
/// with ICU's output (separators, half-even rounding, currency symbols and
/// spacing) checked against Laravel 12:
///
/// ```dart
/// Number.format(1234567.891, precision: 2);          // 1,234,567.89
/// Number.fileSize(5 * 1024 * 1024);                  // 5 MB
/// Number.abbreviate(1230000, precision: 2);          // 1.23M
/// Number.currency(150000, code: 'IDR', locale: 'id'); // Rp 150.000,00
/// Number.ordinal(22);                                // 22nd
/// ```
abstract final class Number {
  static String _locale = 'en';
  static String _currency = 'USD';

  /// The default locale (`Number::useLocale`): `en` or `id`.
  static void useLocale(String locale) => _locale = _localeOf(locale);

  /// The default currency of [currency] (`Number::useCurrency`).
  static void useCurrency(String code) => _currency = code.toUpperCase();

  static String get defaultLocale => _locale;
  static String get defaultCurrency => _currency;

  /// Grouped decimal: up to three fraction digits, [precision] exactly, or up
  /// to [maxPrecision].
  static String format(
    num value, {
    int? precision,
    int? maxPrecision,
    String? locale,
  }) => _decimal(
    value,
    minFraction: maxPrecision != null ? 0 : (precision ?? 0),
    maxFraction: maxPrecision ?? precision ?? 3,
    locale: _localeOf(locale),
  );

  /// `66.666` → `67%` (`Number::percentage`).
  static String percentage(
    num value, {
    int precision = 0,
    int? maxPrecision,
    String? locale,
  }) =>
      '${_decimal(value, minFraction: maxPrecision != null ? 0 : precision, maxFraction: maxPrecision ?? precision, locale: _localeOf(locale))}%';

  /// `150000` with `code: 'IDR'` → `IDR 150,000.00` (`en`) or
  /// `Rp 150.000,00` (`id`), as ICU writes them (the space is U+00A0).
  static String currency(
    num value, {
    String? code,
    String? locale,
    int? precision,
  }) {
    final loc = _localeOf(locale);
    final currencyCode = (code ?? _currency).toUpperCase();
    final digits = precision ?? (_noDecimals.contains(currencyCode) ? 0 : 2);
    final symbol = _symbols[loc]?[currencyCode] ?? currencyCode;
    final amount = _decimal(
      value.abs(),
      minFraction: digits,
      maxFraction: digits,
      locale: loc,
    );
    final space = RegExp(r'\p{L}$', unicode: true).hasMatch(symbol) ? ' ' : '';
    final negative = value < 0 && RegExp('[1-9]').hasMatch(amount);
    return '${negative ? '-' : ''}$symbol$space$amount';
  }

  /// `5242880` → `5 MB` (`Number::fileSize`, 1024-based; a value above 0.9
  /// of the next unit moves to it).
  static String fileSize(num bytes, {int precision = 0, int? maxPrecision}) {
    var value = bytes.toDouble();
    var unit = 0;
    while (value.abs() / 1024 > 0.9 && unit < _fileUnits.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${format(value, precision: precision, maxPrecision: maxPrecision)} '
        '${_fileUnits[unit]}';
  }

  /// `1500` → `2K`, `1230000` with `precision: 2` → `1.23M`.
  static String abbreviate(num value, {int precision = 0, int? maxPrecision}) =>
      _summarize(value, precision, maxPrecision, _short);

  /// `1500` → `2 thousand` (`Number::forHumans`).
  static String forHumans(
    num value, {
    int precision = 0,
    int? maxPrecision,
    bool abbreviate = false,
  }) => _summarize(value, precision, maxPrecision, abbreviate ? _short : _long);

  /// `1` → `1st`, `22` → `22nd`, `111` → `111th` (`en`); `ke-1` (`id`).
  static String ordinal(int value, {String? locale}) {
    final loc = _localeOf(locale);
    final number = format(value, locale: loc);
    if (loc == 'id') {
      return 'ke-$number';
    }
    final lastTwo = value.abs() % 100;
    final suffix = lastTwo >= 11 && lastTwo <= 13
        ? 'th'
        : switch (value.abs() % 10) {
            1 => 'st',
            2 => 'nd',
            3 => 'rd',
            _ => 'th',
          };
    return '$number$suffix';
  }

  /// [value] limited to [min]..[max] (`Number::clamp`).
  static num clamp(num value, num min, num max) =>
      value < min ? min : (value > max ? max : value);

  // -------------------------------------------------------------------------

  static const List<String> _fileUnits = [
    'B',
    'KB',
    'MB',
    'GB',
    'TB',
    'PB',
    'EB',
    'ZB',
    'YB',
  ];

  static const Map<int, String> _short = {
    3: 'K',
    6: 'M',
    9: 'B',
    12: 'T',
    15: 'Q',
  };
  static const Map<int, String> _long = {
    3: ' thousand',
    6: ' million',
    9: ' billion',
    12: ' trillion',
    15: ' quadrillion',
  };

  /// ICU symbols; any other currency is written as its code.
  static const Map<String, Map<String, String>> _symbols = {
    'en': {'USD': r'$', 'EUR': '€', 'GBP': '£', 'JPY': '¥'},
    'id': {'USD': r'US$', 'EUR': '€', 'GBP': '£', 'JPY': 'JP¥', 'IDR': 'Rp'},
  };
  static const Set<String> _noDecimals = {'JPY', 'KRW', 'VND'};

  static String _localeOf(String? locale) {
    final value = (locale ?? _locale).toLowerCase();
    final language = value.split(RegExp('[-_]')).first;
    if (language == 'en' || language == 'id') {
      return language;
    }
    throw ArgumentError.value(locale, 'locale', 'Number supports en and id');
  }

  /// Laravel's `summarize`, including its quirks (`999999` → `1,000K`).
  static String _summarize(
    num value,
    int precision,
    int? maxPrecision,
    Map<int, String> units,
  ) {
    if (value == 0) {
      return precision > 0
          ? format(0, precision: precision, maxPrecision: maxPrecision)
          : '0';
    }
    if (value < 0) {
      return '-${_summarize(-value, precision, maxPrecision, units)}';
    }
    if (value >= 1e15) {
      return '${_summarize(value / 1e15, precision, maxPrecision, units)}'
          '${units[15]}';
    }
    // floor(log10(value)) without floating error at exact powers of ten.
    final exponent = value >= 1 ? value.floor().toString().length - 1 : 0;
    final display = exponent - exponent % 3;
    final scaled = value / _pow10(display);
    return '${format(scaled, precision: precision, maxPrecision: maxPrecision)}'
            '${units[display] ?? ''}'
        .trim();
  }

  static num _pow10(int exponent) {
    var result = 1;
    for (var i = 0; i < exponent; i++) {
      result *= 10;
    }
    return result;
  }

  /// ICU decimal formatting: half-even rounding to [maxFraction] digits,
  /// trailing zeros dropped down to [minFraction], groups of three.
  static String _decimal(
    num value, {
    required int minFraction,
    required int maxFraction,
    required String locale,
  }) {
    final (group, point) = locale == 'id' ? ('.', ',') : (',', '.');
    final factor = _pow10(maxFraction);
    final scaled = value.abs() * factor;
    var whole = scaled.floor();
    final remainder = scaled - whole;
    if (remainder > 0.5 || (remainder == 0.5 && whole.isOdd)) {
      whole += 1;
    }
    final integerDigits = (whole ~/ factor).toString();
    var fraction = maxFraction == 0
        ? ''
        : (whole % factor).toString().padLeft(maxFraction, '0');
    while (fraction.length > minFraction && fraction.endsWith('0')) {
      fraction = fraction.substring(0, fraction.length - 1);
    }
    final grouped = StringBuffer();
    for (var i = 0; i < integerDigits.length; i++) {
      if (i > 0 && (integerDigits.length - i) % 3 == 0) {
        grouped.write(group);
      }
      grouped.write(integerDigits[i]);
    }
    final negative = value < 0 && whole != 0;
    return '${negative ? '-' : ''}$grouped'
        '${fraction.isEmpty ? '' : '$point$fraction'}';
  }
}

/// `5242880.toFileSize()`, `1500.abbreviate()`.
extension DaravelNumber on num {
  String toFileSize({int precision = 0}) =>
      Number.fileSize(this, precision: precision);

  String abbreviate({int precision = 0}) =>
      Number.abbreviate(this, precision: precision);

  String toCurrency({String? code, String? locale}) =>
      Number.currency(this, code: code, locale: locale);
}

/// `22.ordinal()` → `22nd`.
extension DaravelOrdinal on int {
  String ordinal({String? locale}) => Number.ordinal(this, locale: locale);
}
