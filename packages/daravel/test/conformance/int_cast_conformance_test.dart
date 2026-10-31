@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `HasAttributes::castAttribute` is `(int) $value`: PostgreSQL's numeric
/// comes back as a string, and a decimal one must not turn into null.
void main() {
  for (final (value, expected) in <(Object?, int?)>[
    (null, null),
    (7, 7),
    (168.6, 168),
    (-168.6, -168),
    ('42', 42),
    ('168.6', 168),
    ('-3.9', -3),
    (' 12', 12),
    ('12abc', 12),
    ('1e3', 1000),
    ('abc', 0),
    ('', 0),
    (true, 1),
    (false, 0),
  ]) {
    test('(int) $value', () => expect(Cast.integer.get(value), expected));
  }
}
