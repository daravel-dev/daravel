import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Env.of(EnvKey<T>)` (W9.7): a typed read, as `string`, `integer` and
/// `boolean` read.
void main() {
  final env = Env.fromMap({
    'APP_NAME': 'Shop',
    'APP_PORT': '8000',
    'APP_DEBUG': 'yes',
    'BLANK': '',
  });

  test('String, int and bool, with fallbacks', () {
    expect(env.of(const EnvKey<String>('APP_NAME')), 'Shop');
    expect(env.of(const EnvKey<int>('APP_PORT')), 8000);
    expect(env.of(const EnvKey<bool>('APP_DEBUG')), isTrue);
    expect(env.of(const EnvKey<int>('MISSING'), 3), 3);
    expect(env.of(const EnvKey<bool>('MISSING')), isFalse);
    expect(
      () => env.of(const EnvKey<String>('MISSING')),
      throwsA(isA<EnvException>()),
    );
  });

  test('a nullable key is null when not set or empty', () {
    expect(env.of(const EnvKey<int?>('MISSING')), isNull);
    expect(env.of(const EnvKey<String?>('BLANK')), isNull);
    expect(env.of(const EnvKey<int?>('APP_PORT')), 8000);
    expect(env.of(const EnvKey<int?>('MISSING'), 5), 5);
  });

  test('a key is its name', () {
    const key = EnvKey<int>('APP_PORT');
    expect(key, 'APP_PORT');
    expect(env.integer(key), 8000);
  });

  test('another type is refused', () {
    expect(() => env.of(const EnvKey<double>('APP_PORT')), throwsArgumentError);
  });
}
