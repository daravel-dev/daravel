import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `date_format` as Laravel's `validateDateFormat` (laravel/framework
/// v12.70.1, ValidatesAttributes.php): `DateTime::createFromFormat('!' .
/// $format, $value, UTC)` and the value must format back to itself.
void main() {
  Future<Map<String, List<String>>> errors(
    Object? value,
    Object rules, {
    String locale = 'en',
  }) => Validator({'day': value}, {'day': rules}, locale: locale).run();

  group('phpDateMatchesFormat', () {
    test('exact round trips pass', () {
      expect(phpDateMatchesFormat('2026-10-30', 'Y-m-d'), isTrue);
      expect(phpDateMatchesFormat('30/10/2026', 'd/m/Y'), isTrue);
      expect(
        phpDateMatchesFormat('2026-10-30 13:05:09', 'Y-m-d H:i:s'),
        isTrue,
      );
      expect(phpDateMatchesFormat('01:05 PM', 'h:i A'), isTrue);
      expect(phpDateMatchesFormat('2026-1-5', 'Y-n-j'), isTrue);
      expect(phpDateMatchesFormat('Fri, 30 Oct 2026', 'D, d M Y'), isTrue);
      expect(phpDateMatchesFormat('30 October 26', 'd F y'), isTrue);
      expect(phpDateMatchesFormat('20261030', 'Ymd'), isTrue);
      expect(
        phpDateMatchesFormat('2026-10-30T13:05:09+07:00', r'Y-m-d\TH:i:sP'),
        isTrue,
      );
      expect(
        phpDateMatchesFormat('2026-10-30T13:05:09.123456Z', r'Y-m-d\TH:i:s.up'),
        isTrue,
      );
      expect(phpDateMatchesFormat('1793350800', 'U'), isTrue);
    });

    test('what PHP reads differently fails', () {
      // Overflow: Feb 30 becomes Mar 2, which formats differently.
      expect(phpDateMatchesFormat('2026-02-30', 'Y-m-d'), isFalse);
      expect(
        phpDateMatchesFormat('2026-10-30 25:00:00', 'Y-m-d H:i:s'),
        isFalse,
      );
      // Missing leading zeros do not format back.
      expect(phpDateMatchesFormat('2026-1-5', 'Y-m-d'), isFalse);
      // Trailing data and wrong separators.
      expect(phpDateMatchesFormat('2026-10-30x', 'Y-m-d'), isFalse);
      expect(phpDateMatchesFormat('2026/10/30', 'Y-m-d'), isFalse);
      expect(phpDateMatchesFormat('', 'Y-m-d'), isFalse);
      // The wrong day name for the date.
      expect(phpDateMatchesFormat('Mon, 30 Oct 2026', 'D, d M Y'), isFalse);
      expect(phpDateMatchesFormat('13:05 PM', 'h:i A'), isFalse);
    });
  });

  group('the date_format rule', () {
    test('passes, fails, and reads several formats', () async {
      expect(await errors('2026-10-30', 'date_format:Y-m-d'), isEmpty);
      expect(await errors('30/10/2026', 'date_format:Y-m-d,d/m/Y'), isEmpty);
      expect(await errors(20261030, 'date_format:Ymd'), isEmpty);
      expect((await errors('2026-02-30', 'date_format:Y-m-d'))['day'], [
        'The day field must match the format Y-m-d.',
      ]);
      // Arrays and booleans are neither strings nor numbers.
      expect(await errors(['2026-10-30'], 'date_format:Y-m-d'), isNotEmpty);
      expect(await errors(true, 'date_format:Y-m-d'), isNotEmpty);
    });

    test('nullable and empty strings skip it, as other rules', () async {
      expect(await errors(null, 'nullable|date_format:Y-m-d'), isEmpty);
      expect(await errors('', 'date_format:Y-m-d'), isEmpty);
    });

    test('messages in Indonesian and in Laravel 8/9 wording', () async {
      expect((await errors('x', 'date_format:Y-m-d', locale: 'id'))['day'], [
        'Kolom day harus sesuai dengan format Y-m-d.',
      ]);
      expect(
        ValidationMessages.legacyEnglish['date_format'],
        'The :attribute does not match the format :format.',
      );
    });

    test('a format containing a comma goes through the builder', () async {
      final result = await Validator(
        {'day': 'Oct 30, 2026'},
        {
          'day': [
            Rules.dateFormat(['M d, Y']),
          ],
        },
      ).run();
      expect(result, isEmpty);
    });
  });
}
