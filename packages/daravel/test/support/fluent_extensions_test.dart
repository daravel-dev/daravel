import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Expected values are Laravel 12.70.1 / Carbon 3.15 output (intl ICU),
/// captured with PHP from a Laravel application.
void main() {
  group('Number (Laravel 12)', () {
    test('fileSize', () {
      expect(Number.fileSize(0), '0 B');
      expect(Number.fileSize(921), '921 B');
      expect(Number.fileSize(922), '1 KB');
      expect(Number.fileSize(1023), '1 KB');
      expect(Number.fileSize(1536), '2 KB');
      expect(Number.fileSize(1536, precision: 2), '1.50 KB');
      expect(Number.fileSize(1000, precision: 2), '0.98 KB');
      expect(Number.fileSize(5 * 1024 * 1024), '5 MB');
      expect(Number.fileSize(1610612736, precision: 1), '1.5 GB');
    });

    test('abbreviate and forHumans, quirks included', () {
      expect(Number.abbreviate(0), '0');
      expect(Number.abbreviate(999), '999');
      expect(Number.abbreviate(1000), '1K');
      expect(Number.abbreviate(1500), '2K');
      expect(Number.abbreviate(1500, precision: 1), '1.5K');
      expect(Number.abbreviate(489939), '490K');
      expect(Number.abbreviate(1230000, precision: 2), '1.23M');
      expect(Number.abbreviate(2000000000), '2B');
      expect(Number.abbreviate(1.5e12), '2T');
      expect(Number.abbreviate(-1500), '-2K');
      expect(Number.abbreviate(999999), '1,000K');
      expect(Number.abbreviate(1e15), '1Q');
      expect(Number.abbreviate(1e18), '1KQ');
      expect(Number.abbreviate(1234, maxPrecision: 2), '1.23K');
      expect(Number.forHumans(1500), '2 thousand');
    });

    test('format and percentage round half to even', () {
      expect(Number.format(1234567.891), '1,234,567.891');
      expect(Number.format(1234567.891, precision: 2), '1,234,567.89');
      expect(Number.format(1000, precision: 0), '1,000');
      expect(Number.format(1234.56789), '1,234.568');
      expect(Number.format(0.5), '0.5');
      expect(Number.format(1.005, precision: 2), '1.00');
      expect(Number.format(2.5, precision: 0), '2');
      expect(Number.format(3.5, precision: 0), '4');
      expect(Number.format(-1234.5), '-1,234.5');
      expect(Number.format(1.5, maxPrecision: 2), '1.5');
      expect(
        Number.format(1234567.891, precision: 2, locale: 'id'),
        '1.234.567,89',
      );
      expect(Number.format(0.5, locale: 'id'), '0,5');
      expect(Number.percentage(66.666), '67%');
      expect(Number.percentage(66.666, precision: 1), '66.7%');
      expect(Number.percentage(10), '10%');
      expect(Number.percentage(0.5), '0%');
      expect(Number.percentage(1234.5, precision: 1), '1,234.5%');
      expect(Number.percentage(12.5, precision: 1, locale: 'id'), '12,5%');
    });

    test('currency symbols and spacing as ICU writes them', () {
      const nbsp = ' ';
      expect(Number.currency(150000), r'$150,000.00');
      expect(Number.currency(150000, code: 'IDR'), 'IDR${nbsp}150,000.00');
      expect(
        Number.currency(150000, code: 'IDR', locale: 'id'),
        'Rp${nbsp}150.000,00',
      );
      expect(Number.currency(150000, code: 'EUR'), '€150,000.00');
      expect(Number.currency(-1234.5, code: 'USD'), r'-$1,234.50');
      expect(Number.currency(-1234.5, code: 'JPY'), '-¥1,234');
      expect(Number.currency(-1234.5, code: 'SGD'), '-SGD${nbsp}1,234.50');
      expect(
        Number.currency(-1234.5, code: 'USD', locale: 'id'),
        r'-US$1.234,50',
      );
      expect(Number.currency(-1234.5, code: 'JPY', locale: 'id'), '-JP¥1.234');
      expect(
        Number.currency(-1234.5, code: 'IDR', locale: 'id'),
        '-Rp${nbsp}1.234,50',
      );
      expect(Number.currency(1234.5, code: 'USD', precision: 0), r'$1,234');
    });

    test('ordinal, defaults and extensions', () {
      for (final MapEntry(:key, :value) in {
        0: '0th',
        1: '1st',
        2: '2nd',
        3: '3rd',
        4: '4th',
        11: '11th',
        12: '12th',
        13: '13th',
        21: '21st',
        22: '22nd',
        101: '101st',
        111: '111th',
        112: '112th',
        1001: '1,001st',
      }.entries) {
        expect(Number.ordinal(key), value, reason: '$key');
      }
      expect(Number.ordinal(1, locale: 'id'), 'ke-1');
      expect(5242880.toFileSize(), '5 MB');
      expect(1500.abbreviate(precision: 1), '1.5K');
      expect(22.ordinal(), '22nd');
      addTearDown(() {
        Number.useLocale('en');
        Number.useCurrency('USD');
      });
      Number.useLocale('id_ID');
      Number.useCurrency('idr');
      expect(150000.toCurrency(), 'Rp 150.000,00');
      expect(() => Number.format(1, locale: 'de'), throwsArgumentError);
    });
  });

  group('time (Carbon 3)', () {
    final now = DateTime.utc(2026, 10, 25, 12);
    setUp(() => Clock.travelTo(now));
    tearDown(Clock.restore);

    test('diffForHumans picks the largest calendar unit', () {
      String ago(Duration d) => now.subtract(d).diffForHumans();
      DateTime daysBack(int days) => DateTime.utc(2026, 10, 25 - days, 12);
      expect(now.diffForHumans(), '0 seconds ago');
      expect(ago(1.seconds), '1 second ago');
      expect(ago(59.seconds), '59 seconds ago');
      expect(ago(90.seconds), '1 minute ago');
      expect(ago(2.minutes), '2 minutes ago');
      expect(ago(const Duration(minutes: 59, seconds: 59)), '59 minutes ago');
      expect(ago(90.minutes), '1 hour ago');
      expect(
        ago(const Duration(hours: 23, minutes: 59, seconds: 59)),
        '23 hours ago',
      );
      expect(ago(36.hours), '1 day ago');
      expect(daysBack(6).diffForHumans(), '6 days ago');
      expect(daysBack(13).diffForHumans(), '1 week ago');
      expect(daysBack(14).diffForHumans(), '2 weeks ago');
      expect(daysBack(29).diffForHumans(), '4 weeks ago');
      expect(daysBack(30).diffForHumans(), '1 month ago');
      expect(daysBack(59).diffForHumans(), '1 month ago');
      expect(daysBack(60).diffForHumans(), '1 month ago');
      expect(daysBack(61).diffForHumans(), '2 months ago');
      expect(daysBack(364).diffForHumans(), '11 months ago');
      expect(daysBack(365).diffForHumans(), '1 year ago');
      expect(now.add(1.minutes).diffForHumans(), '1 minute from now');
      expect(now.add(2.hours).diffForHumans(), '2 hours from now');
      expect(now.add(2.days).diffForHumans(), '2 days from now');
      expect(
        now.subtract(1.hours).diffForHumans(other: now.add(1.days)),
        contains('before'),
      );
      expect(
        daysBack(1).diffForHumans(other: now.add(1.days)),
        '2 days before',
      );
    });

    test('Indonesian, as Carbon translates it', () {
      expect(now.diffForHumans(locale: 'id'), '0 detik yang lalu');
      expect(
        now.subtract(5.minutes).diffForHumans(locale: 'id'),
        '5 menit yang lalu',
      );
      expect(
        now.subtract(7.days).diffForHumans(locale: 'id'),
        '1 minggu yang lalu',
      );
      expect(
        DateTime.utc(2025, 10, 25, 12).diffForHumans(locale: 'id'),
        '1 tahun yang lalu',
      );
      expect(
        now.add(2.hours).diffForHumans(locale: 'id'),
        '2 jam dari sekarang',
      );
      expect(
        now.subtract(1.days).diffForHumans(other: now, locale: 'id'),
        '1 hari sebelumnya',
      );
    });

    test('durations and Clock-aware helpers', () {
      expect(10.minutes, const Duration(minutes: 10));
      expect(2.weeks, const Duration(days: 14));
      expect(15.minutes.fromNow, now.add(const Duration(minutes: 15)));
      expect(7.days.ago, now.subtract(const Duration(days: 7)));
      expect(now.subtract(1.seconds).isPast, isTrue);
      expect(now.add(1.seconds).isFuture, isTrue);
      expect(DateTime.utc(2026, 10, 25, 23).isToday, isTrue);
      expect(DateTime.utc(2026, 10, 26).isToday, isFalse);
      expect(now.startOfDay, DateTime.utc(2026, 10, 25));
      expect(now.endOfDay, DateTime.utc(2026, 10, 25, 23, 59, 59, 999, 999));
    });
  });

  test('string chains delegate to Str', () {
    expect(
      'Breaking: Hello   World! '.after(':').squish().slug(),
      'hello-world',
    );
    expect('blog_posts'.singular().studly(), 'BlogPost');
    expect(
      'taylor@example.com'.mask('*', 3),
      Str.mask('taylor@example.com', '*', 3),
    );
    expect('user'.plural(), 'users');
    expect('hello world'.title(), 'Hello World');
    expect('a b c'.wordCount, 3);
    expect('{"a":1}'.isJson, isTrue);
    expect(
      'Daravel and Laravel'.containsAll([
        'daravel',
        'LARAVEL',
      ], ignoreCase: true),
      isTrue,
    );
    String? missing;
    expect(missing.isBlank, isTrue);
    expect('  '.isBlank, isTrue);
    expect(missing.orEmpty, '');
    expect(' '.nullIfBlank, isNull);
    expect('x'.isFilled, isTrue);
  });
}
