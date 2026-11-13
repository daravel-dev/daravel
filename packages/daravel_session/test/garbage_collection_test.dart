import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String appKey = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Wins every session lottery.
final class _AlwaysWin implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 0;
}

/// A handler whose sweeps wait for [release] and are counted.
final class _SlowHandler implements SessionHandler {
  int sweeps = 0;
  Completer<void> release = Completer<void>();
  Object? error;

  @override
  Future<String?> read(String id) async => null;

  @override
  Future<void> write(String id, String payload, {Request? request}) async {}

  @override
  Future<void> destroy(String id) async {}

  @override
  Future<void> gc(Duration lifetime) async {
    sweeps++;
    await release.future;
    if (error case final error?) {
      throw error;
    }
  }
}

void main() {
  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('daravel_session_gc_');
  });

  tearDown(() {
    travelBack();
    if (base.existsSync()) {
      base.deleteSync(recursive: true);
    }
  });

  /// [count] session files named `<prefix><n>`, [age] old by the wall clock.
  void files(String dir, String prefix, int count, {Duration? age}) {
    Directory(dir).createSync(recursive: true);
    final stamp = age == null ? null : DateTime.now().subtract(age);
    for (var i = 0; i < count; i++) {
      final file = File(p.join(dir, '$prefix${'$i'.padLeft(6, '0')}'))
        ..writeAsStringSync('a:0:{}');
      if (stamp != null) {
        file.setLastModifiedSync(stamp);
      }
    }
  }

  List<String> left(String dir, String prefix) => [
    for (final entry in Directory(dir).listSync())
      if (p.basename(entry.path).startsWith(prefix)) entry.path,
  ];

  group('FileSessionHandler.gc', () {
    const lifetime = Duration(minutes: 120);

    test('deletes the files idle for longer than the lifetime, by '
        'Clock.now()', () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'old', 5, age: const Duration(minutes: 121));
      files(dir, 'new', 5);
      final handler = FileSessionHandler(dir, lifetime: lifetime);
      await handler.gc(lifetime);
      expect(left(dir, 'old'), isEmpty);
      expect(left(dir, 'new'), hasLength(5));

      travel(const Duration(minutes: 121));
      expect(
        await handler.read('new000000'),
        isNull,
        reason: 'travel() ages the files',
      );
      await handler.gc(lifetime);
      expect(left(dir, 'new'), isEmpty);
    });

    test('a clock moved back expires nothing', () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'new', 5);
      final handler = FileSessionHandler(dir, lifetime: lifetime);
      travel(const Duration(hours: -3));
      await handler.gc(lifetime);
      expect(left(dir, 'new'), hasLength(5));
      expect(await handler.read('new000000'), 'a:0:{}');
    });

    test('one call examines at most gcBatch files', () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'old', 250, age: const Duration(hours: 3));
      final handler = FileSessionHandler(dir, lifetime: lifetime, gcBatch: 100);
      await handler.gc(lifetime);
      expect(left(dir, 'old'), hasLength(150));
      await handler.gc(lifetime);
      await handler.gc(lifetime);
      expect(left(dir, 'old'), isEmpty);
    });

    test('one call stops after gcBudget, having examined at least one '
        'file', () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'old', 300, age: const Duration(hours: 3));
      final handler = FileSessionHandler(
        dir,
        lifetime: lifetime,
        gcBudget: const Duration(microseconds: 1),
      );
      await handler.gc(lifetime);
      final remaining = left(dir, 'old').length;
      expect(remaining, lessThan(300), reason: 'it made progress');
      expect(remaining, greaterThan(0), reason: 'it stopped on the budget');
    });

    test(
      'expired files listed after more active files than one call '
      'examines are reached: each call resumes where the last stopped',
      () async {
        final dir = p.join(base.path, 'sessions');
        // Listed first on NTFS and APFS (by name); the order is the file
        // system's elsewhere, which the test does not depend on.
        files(dir, 'a', 2000);
        files(dir, 'z', 300, age: const Duration(hours: 3));
        final handler = FileSessionHandler(
          dir,
          lifetime: lifetime,
          gcBatch: 200,
        );
        var calls = 0;
        while (left(dir, 'z').isNotEmpty && calls < 30) {
          await handler.gc(lifetime);
          calls++;
        }
        expect(left(dir, 'z'), isEmpty, reason: 'after $calls calls');
        expect(left(dir, 'a'), hasLength(2000));
        expect(calls, lessThanOrEqualTo(13), reason: '2 300 files / 200 + 1');
      },
    );

    test('a call that stops early releases the directory', () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'a', 50);
      final handler = FileSessionHandler(dir, lifetime: lifetime, gcBatch: 10);
      await handler.gc(lifetime);
      expect(handler.gcPosition, 10, reason: 'stopped before the end');
      Directory(dir).deleteSync(recursive: true);
      expect(Directory(dir).existsSync(), isFalse);
      await handler.gc(lifetime);
      expect(handler.gcPosition, 0);
    });
  });

  group('the lottery', () {
    late Application app;
    late TestClient client;
    late _SlowHandler handler;
    late MemoryHandler logs;
    var closed = false;

    setUp(() async {
      closed = false;
      app = Application.configure(basePath: base.path)
          .withEnv(const {
            'APP_ENV': 'testing',
            'APP_KEY': appKey,
            'DB_DATABASE': ':memory:',
            'SESSION_DRIVER': 'array',
          })
          .withLogLevel(LogLevel.debug)
          .withSession()
          .withMiddleware(
            (m) => m.alias(
              'session_gc',
              StartSessionMiddleware(lottery: _AlwaysWin()),
            ),
          )
          .withRouting(
            web: (router) =>
                router.get('/', (request) => {'ok': true})
                  ..middleware(const ['session_gc']),
          )
          .create();
      await app.boot();
      handler = _SlowHandler();
      logs = await app.run(() async {
        App.make<SessionManager>().extend('array', (_) => handler);
        return Log.spy();
      });
      client = TestClient(app);
    });

    tearDown(() async {
      if (!handler.release.isCompleted) {
        handler.release.complete();
      }
      if (!closed) {
        await app.shutdown();
      }
    });

    SessionGarbageCollector collector() =>
        app.container.make<SessionManager>().garbageCollector;

    test('the winning request does not wait for the sweep', () async {
      final response = await client
          .get('/')
          .timeout(const Duration(seconds: 5));
      response.assertOk();
      expect(handler.sweeps, 1);
      expect(collector().running, isNotNull, reason: 'still sweeping');
      handler.release.complete();
      await collector().running;
      expect(collector().running, isNull);
    });

    test('one sweep at a time', () async {
      (await client.get('/')).assertOk();
      (await client.get('/')).assertOk();
      expect(handler.sweeps, 1);
      handler.release.complete();
      await collector().running;
      (await client.get('/')).assertOk();
      expect(handler.sweeps, 2);
    });

    test('a failing sweep is logged by name and the next one runs', () async {
      handler.error = StateError('disk gone');
      (await client.get('/')).assertOk();
      handler.release.complete();
      await collector().running;
      expect(
        logs.matching(LogLevel.error, 'Detached task session gc'),
        hasLength(1),
      );
      (await client.get('/')).assertOk();
      expect(handler.sweeps, 2);
    });

    test('the shutdown waits for the sweep in progress and starts no '
        'other', () async {
      (await client.get('/')).assertOk();
      var down = false;
      final shutdown = app.shutdown().then((_) => down = true);
      closed = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(down, isFalse, reason: 'waits for the sweep');
      handler.release.complete();
      await shutdown;
      expect(down, isTrue);
      expect(collector().trigger(), isNull);
      expect(handler.sweeps, 1);
    });
  });
}
