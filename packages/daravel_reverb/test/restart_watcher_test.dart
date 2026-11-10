import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:test/test.dart';

Future<Application> booted() async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .create();
  await app.boot();
  addTearDown(app.shutdown);
  return app;
}

/// Lets the watcher's polls run (a few milliseconds each).
Future<void> polls([int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late MemoryStore signals;

  setUp(() => signals = MemoryStore());

  Future<(Application, ReverbRestartWatcher)> watching() async {
    final app = await booted();
    final watcher = ReverbRestartWatcher(
      app,
      signals,
      poll: const Duration(milliseconds: 2),
      spread: Duration.zero,
    )..start();
    addTearDown(watcher.stop);
    return (app, watcher);
  }

  Future<void> request(Object value) => signals.put(reverbRestartKey, value);

  test('a request already there at the start, even "from the future", is '
      'not one', () async {
    // Another machine's clock, ahead of this one.
    await request(
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
    );
    final (app, watcher) = await watching();
    await polls();
    expect(app.restartRequested, isFalse);
    expect(watcher.watching, isTrue);
  });

  test('a changed value restarts once; the worker spawned again does not '
      'restart again', () async {
    await request(1);
    final (app, watcher) = await watching();
    await polls();
    expect(app.restartRequested, isFalse);

    // An earlier time than the one there: still a new request.
    await request(0);
    await polls();
    expect(app.restartRequested, isTrue);
    expect(watcher.watching, isFalse);

    final (respawned, again) = await watching();
    await polls();
    expect(respawned.restartRequested, isFalse);
    expect(again.watching, isTrue);
  });

  test('a key never set, then set, is a request', () async {
    final (app, _) = await watching();
    await polls();
    expect(app.restartRequested, isFalse);
    await request(DateTime.now().millisecondsSinceEpoch);
    await polls();
    expect(app.restartRequested, isTrue);
  });
}
