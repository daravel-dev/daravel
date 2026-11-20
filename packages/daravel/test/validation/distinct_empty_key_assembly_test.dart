import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Where the empty-key fix of `expandPattern` and `distinct` reading its
/// pattern meet: a top-level wildcard over an empty key. `expandPattern`
/// writes the empty key as an empty segment (`.id`); `distinct` compares
/// that value with the others and not theirs with it, as Laravel's `[^.]+`
/// never matches an empty key (`ValidatesAttributes.php` 12.x :919-930).
void main() {
  Future<Set<String>> failing(
    Map<String, Object?> data,
    String pattern,
  ) async => (await Validator(data, {pattern: 'distinct'}).run()).keys.toSet();

  test('*.id under an empty top-level key: its value is compared with the '
      'others', () async {
    expect(
      Validator.expandPattern({
        '': {'id': 1},
        'x': {'id': 1},
      }, '*.id'),
      ['.id', 'x.id'],
    );
    expect(
      await failing({
        '': {'id': 1},
        'x': {'id': 1},
      }, '*.id'),
      {'.id'},
    );
  });

  test('*.id under an empty top-level key, no other equal value: '
      'passes', () async {
    expect(
      await failing({
        '': {'id': 1},
        'x': {'id': 2},
      }, '*.id'),
      isEmpty,
    );
  });

  test('*.* with duplicates under the empty top-level key only: passes, as '
      'in Laravel (nothing matches [^.]+)', () async {
    expect(
      await failing({
        '': ['dup', 'dup'],
      }, '*.*'),
      isEmpty,
    );
  });
}
