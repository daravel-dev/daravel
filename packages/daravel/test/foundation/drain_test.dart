import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('DrainSignal', () {
    test(
      'onDrain listeners run once on signal and can be removed (#150)',
      () async {
        final drain = DrainSignal();
        final calls = <String>[];
        final removeA = drain.onDrain(() => calls.add('a'));
        drain.onDrain(() => calls.add('b'));
        expect(drain.listenerCount, 2);
        removeA();
        removeA(); // twice is fine
        expect(drain.listenerCount, 1);

        drain
          ..signal()
          ..signal();
        expect(calls, ['b']);
        expect(drain.listenerCount, 0);
        expect(drain.isDraining, isTrue);
        await drain.future;

        // Added after the signal: called soon, nothing kept.
        final late = Completer<void>();
        drain.onDrain(late.complete);
        expect(drain.listenerCount, 0);
        await late.future;
      },
    );

    test('a failing listener does not keep the others from running', () {
      final drain = DrainSignal();
      final calls = <String>[];
      final errors = <Object>[];
      runZonedGuarded(() {
        drain
          ..onDrain(() => throw StateError('boom'))
          ..onDrain(() => calls.add('ok'))
          ..signal();
      }, (error, _) => errors.add(error));
      expect(calls, ['ok']);
      expect(errors, [isA<StateError>()]);
    });
  });
}
