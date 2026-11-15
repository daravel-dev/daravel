import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('an error reaches callers in two request zones', () async {
    final container = Container();
    final made = Completer<SharedResult<int>>();
    final uncaught = <Object>[];

    Future<String> inRequest(Future<String> Function() body) =>
        container.runScoped(
          'request',
          (_) => body(),
          onUncaughtError: (error, _) => uncaught.add(error),
        );

    final first = inRequest(() async {
      final shared = SharedResult<int>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw StateError('boom');
      });
      made.complete(shared);
      try {
        await shared.value;
        return 'value';
      } on StateError catch (error) {
        return error.message;
      }
    });
    final second = inRequest(() async {
      final shared = await made.future;
      try {
        await shared.value;
        return 'value';
      } on StateError catch (error) {
        return error.message;
      }
    });

    expect(
      await Future.wait([first, second]).timeout(const Duration(seconds: 2)),
      ['boom', 'boom'],
    );
    expect(uncaught, isEmpty);
  });
}
