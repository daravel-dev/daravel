import 'dart:async';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Container container;
  final uncaught = <Object>[];

  setUp(() {
    container = Container();
    uncaught.clear();
  });

  /// Runs [body] in a request scope of its own, as a request does.
  Future<R> inRequest<R>(Future<R> Function() body) => container.runScoped(
    'request',
    (_) => body(),
    onUncaughtError: (error, _) => uncaught.add(error),
  );

  group('SharedResult', () {
    test('a failure reaches every caller, each in its own zone, none '
        'hangs and nothing is left uncaught', () async {
      final made = Completer<SharedResult<int>>();
      Future<String> caller({required bool starts}) => inRequest(() async {
        final shared = starts
            ? SharedResult<int>(() async {
                await Future<void>.delayed(const Duration(milliseconds: 20));
                throw StateError('boom');
              })
            : await made.future;
        if (starts) {
          made.complete(shared);
        }
        try {
          await shared.value;
          return 'value';
        } on StateError catch (error) {
          return error.message;
        }
      });
      final answers = await Future.wait([
        caller(starts: true),
        caller(starts: false),
        caller(starts: false),
      ]).timeout(const Duration(seconds: 2));
      expect(answers, ['boom', 'boom', 'boom']);
      expect(uncaught, isEmpty);
    });

    test('the error keeps its own stack trace', () async {
      StackTrace? thrownAt;
      final shared = SharedResult<void>(() async {
        try {
          throw ArgumentError('bad');
        } on ArgumentError catch (_, stack) {
          thrownAt = stack;
          rethrow;
        }
      });
      try {
        await shared.value;
        fail('no error');
      } on ArgumentError catch (_, stack) {
        expect(stack.toString(), thrownAt.toString());
      }
    });

    test('a programming error is raised to every caller as well', () async {
      final shared = SharedResult<int>(() async => throw UnsupportedError('x'));
      await expectLater(shared.value, throwsUnsupportedError);
      await expectLater(shared.value, throwsUnsupportedError);
    });

    test('a value reaches every caller; done never fails', () async {
      final shared = SharedResult<int>(() async => 42);
      final values = await Future.wait([
        inRequest(() => shared.value),
        inRequest(() => shared.value),
      ]);
      expect(values, [42, 42]);
      await SharedResult<int>(() async => throw StateError('x')).done;
    });
  });

  group('rate limit leases (ProcessRateLimitStore)', () {
    test('a coordinator that does not answer: every request waiting on the '
        'same lease fails open in time, none hangs', () async {
      // A coordinator port that never answers.
      final silent = RawReceivePort((Object? _) {});
      addTearDown(silent.close);
      final channel = RemoteCoordinatorChannel(silent.sendPort);
      addTearDown(channel.close);
      final store = ProcessRateLimitStore(
        channel,
        timeout: const Duration(milliseconds: 200),
      );
      final watch = Stopwatch()..start();
      final results = await Future.wait([
        // Over the lease threshold, so the attempts share one lease
        // request; each from a request of its own.
        for (var i = 0; i < 8; i++)
          inRequest(
            () => store.attempt('shared-key', 1000, const Duration(minutes: 1)),
          ),
      ]).timeout(const Duration(seconds: 5));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(results.every((r) => r.allowed && r.degraded), isTrue);
      expect(uncaught, isEmpty);
    });
  });
}
