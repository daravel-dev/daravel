import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('advises more isolates only for one isolate in production', () {
    final advice = isolateSizingAdvice(
      production: true,
      isolates: 1,
      processors: 8,
    );
    expect(advice, startsWith('APP_ISOLATES=1 on 8 cores'));
    expect(advice, contains('RateLimiter'));
    expect(
      isolateSizingAdvice(production: false, isolates: 1, processors: 8),
      isNull,
    );
    expect(
      isolateSizingAdvice(production: true, isolates: 4, processors: 8),
      isNull,
    );
    expect(
      isolateSizingAdvice(production: true, isolates: 1, processors: 1),
      isNull,
    );
  });
}
