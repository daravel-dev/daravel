@Tags(['conformance'])
library;

import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// How `json_encode` writes a double, checked against PHP 8.3.36 with
/// `serialize_precision = -1` (the default). The right-hand values were
/// recorded with `php -r 'echo json_encode($v);'` in that PHP.
///
/// php-src `php-8.3.36`: `ext/json/json_encoder.c` 92–105
/// (`php_json_encode_double`: `zend_gcvt(d, (int)PG(serialize_precision),
/// '.', 'e', num)`, `.0` only with `JSON_PRESERVE_ZERO_FRACTION`) and 666–672
/// (INF or NaN: `PHP_JSON_ERROR_INF_OR_NAN`); `Zend/zend_strtod.c` 4517–4612
/// (`zend_gcvt`: mode 0 with 17 digits, E-style when `decpt > 17` or
/// `decpt < -3`).
void main() {
  const vectors = <(double, String)>[
    (0.0, '0'),
    (-0.0, '-0'),
    (1.0, '1'),
    (-1.0, '-1'),
    (115.0, '115'),
    (115.1837, '115.1837'),
    (-8.7837, '-8.7837'),
    (0.1, '0.1'),
    (0.30000000000000004, '0.30000000000000004'),
    (0.3333333333333333, '0.3333333333333333'),
    (0.6666666666666666, '0.6666666666666666'),
    (0.0001, '0.0001'),
    (1e-5, '1.0e-5'),
    (1.5e-5, '1.5e-5'),
    (0.000123, '0.000123'),
    (1e14, '100000000000000'),
    (1e15, '1000000000000000'),
    (1e16, '10000000000000000'),
    (1e17, '1.0e+17'),
    (1e20, '1.0e+20'),
    (1.5e15, '1500000000000000'),
    (123456789012345.0, '123456789012345'),
    (1234567890123456.0, '1234567890123456'),
    (12345678901234568.0, '12345678901234568'),
    (9007199254740992.0, '9007199254740992'),
    (1.7976931348623157e308, '1.7976931348623157e+308'),
    (5e-324, '5.0e-324'),
    (2.5, '2.5'),
    (100.5, '100.5'),
    (1e21, '1.0e+21'),
    (1e22, '1.0e+22'),
    (0.00001234, '1.234e-5'),
    (1234560000000.0, '1234560000000'),
    (-1e-7, '-1.0e-7'),
  ];

  test('every recorded double, alone and inside an array', () {
    expect(vectors, hasLength(34));
    for (final (value, php) in vectors) {
      expect(phpJsonDouble(value), php, reason: '$value');
      expect(Response.encodePhpJson([value]), '[$php]', reason: '$value');
    }
  });

  test('integers are unchanged; a whole double drops its .0', () {
    expect(Response.encodePhpJson({'i': 2, 'd': 2.0}), '{"i":2,"d":2}');
    expect(
      Response.encodePhpJson({
        'type': 'Point',
        'coordinates': [0.0, 0.0],
      }),
      '{"type":"Point","coordinates":[0,0]}',
    );
  });

  test('INF and NaN make json_encode fail, as in PHP', () {
    expect(
      () => Response.encodePhpJson(double.infinity),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(
      () => Response.encodePhpJson(double.nan),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
  });
}
