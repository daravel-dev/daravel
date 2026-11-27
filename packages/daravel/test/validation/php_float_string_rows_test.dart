import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/src/validation/php_compare.dart';
import 'package:test/test.dart';

/// `phpNumberString` against PHP itself: every row of
/// `fixtures/php_float_string_rows.json` is a double (the 16 hex digits of
/// its bits) and the text PHP's `(string) $float` gives for it, written by
/// `tool/validation/php_float_string_rows.php` with a real PHP (the
/// fixture says which). The test reads the fixture; it does not run PHP.
///
/// The rows cover what `zend_gcvt` and `zend_dtoa` (mode 2, 14 digits)
/// decide: where the fixed notation ends, how a 15th digit is rounded away
/// (an exact tie goes to the even digit), and the one place where zeros at
/// the end of the 14 digits stay: an integer of 15 digits ending in 5 whose
/// 14th digit is even, so the tie is rounded down (`100000000000005.0` is
/// `1.0000000000000E+14`, where `100000000000000.0` is `1.0E+14`).
void main() {
  final fixture = jsonDecode(
    File('test/validation/fixtures/php_float_string_rows.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final kinds = (fixture['kinds']! as Map<String, Object?>).map(
    (kind, rows) =>
        MapEntry(kind, (rows! as List<Object?>).cast<List<Object?>>()),
  );

  double fromHex(String hex) {
    final bytes = ByteData(8)
      ..setUint32(0, int.parse(hex.substring(0, 8), radix: 16))
      ..setUint32(4, int.parse(hex.substring(8), radix: 16));
    return bytes.getFloat64(0);
  }

  test('the fixture is from PHP 8 with precision 14', () {
    expect(fixture['php'], startsWith('8.'));
    expect(fixture['precision'], 14);
    final rows = kinds.values.fold(0, (sum, rows) => sum + rows.length);
    expect(rows, fixture['rows']);
    expect(rows, greaterThanOrEqualTo(20000));
    expect(kinds['random bits'], hasLength(greaterThanOrEqualTo(5000)));
    expect(kinds['table of the 1.x line'], hasLength(408));
  });

  for (final MapEntry(key: kind, value: rows) in kinds.entries) {
    test('as PHP writes it: $kind (${rows.length} rows)', () {
      final wrong = <String>[];
      for (final [hex as String, text as String] in rows) {
        final written = phpNumberString(fromHex(hex));
        if (written != text) {
          wrong.add('$hex (${fromHex(hex)}): PHP $text, here $written');
        }
      }
      expect(
        wrong,
        isEmpty,
        reason:
            '${wrong.length} of ${rows.length} rows differ, the first:\n'
            '${wrong.take(20).join('\n')}',
      );
    });
  }

  test('the three known rows, and what is beside them', () {
    // Zeros kept: 15 digits, the last a 5, the 14th even.
    expect(phpNumberString(339499579592405.0), '3.3949957959240E+14');
    expect(phpNumberString(100000000000005.0), '1.0000000000000E+14');
    expect(phpNumberString(200000000000005.0), '2.0000000000000E+14');
    expect(phpNumberString(-100000000000005.0), '-1.0000000000000E+14');
    expect(phpNumberString(123456789012005.0), '1.2345678901200E+14');
    // No zero at the end of the 14 digits: nothing to see.
    expect(phpNumberString(123456789012345.0), '1.2345678901234E+14');
    // The 14th digit is odd: rounded up, no zeros.
    expect(phpNumberString(100000000000015.0), '1.0000000000002E+14');
    expect(phpNumberString(100000000000095.0), '1.000000000001E+14');
    // Not a tie, or not an integer: the zeros go.
    expect(phpNumberString(100000000000000.0), '1.0E+14');
    expect(phpNumberString(100000000000004.0), '1.0E+14');
    expect(phpNumberString(100000000000006.0), '1.0000000000001E+14');
    expect(phpNumberString(10000000000000.5), '10000000000000');
    // 16 digits: no zeros kept.
    expect(phpNumberString(1000000000000050.0), '1.0E+15');
    // The sign of zero, and what is not a number.
    expect(phpNumberString(-0.0), '-0');
    expect(phpNumberString(0.0), '0');
    expect(phpNumberString(double.nan), 'NAN');
    expect(phpNumberString(double.infinity), 'INF');
    expect(phpNumberString(double.negativeInfinity), '-INF');
    expect(phpNumberString(9007199254740993), '9007199254740993');
  });
}
