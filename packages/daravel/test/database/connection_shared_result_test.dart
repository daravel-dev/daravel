import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A connection opened for several requests at once is one computation
/// shared between callers of different zones: when it fails to open,
/// every request asking for it gets the error, in its own zone, and none
/// hangs (a stored future that fails delivers its error only in the zone
/// it was made in).
void main() {
  late Container container;
  final uncaught = <Object>[];

  setUp(() {
    container = Container();
    uncaught.clear();
  });

  /// [body] in a request scope of its own, as a request runs.
  Future<R> inRequest<R>(Future<R> Function() body) => container.runScoped(
    'request',
    (_) => body(),
    onUncaughtError: (error, _) => uncaught.add(error),
  );

  /// Two callers, each in its own request, joining one computation: what
  /// each got, within a few seconds (a hang fails the test).
  Future<List<String>> both(Future<Object?> Function() call) => Future.wait([
    for (var i = 0; i < 2; i++)
      inRequest(() async {
        try {
          await call();
          return 'value';
        } on Object catch (error) {
          return error.runtimeType.toString();
        }
      }),
  ]).timeout(const Duration(seconds: 5));

  test('a connection that fails to open reaches every request asking for '
      'it', () async {
    final db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'main',
        connections: {
          'main': ConnectionConfig(driver: 'failing', database: 'x'),
        },
      ),
      drivers: {'failing': (name, _) => _FailingDriver(name)},
    );
    final answers = await both(db.connection);
    expect(answers, ['StateError', 'StateError']);
    expect(uncaught, isEmpty);
  });
}

/// A driver whose connection fails after a moment.
final class _FailingDriver implements DatabaseDriver {
  _FailingDriver(this.name);

  @override
  final String name;

  @override
  Future<void> connect() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    throw StateError('cannot connect');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
