import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

String where() => Isolate.current.debugName ?? '';

int boom() => throw const FormatException('boom');
String meet(String mine, String theirs) {
  File(mine).writeAsStringSync('here');
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!File(theirs).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('The other task never ran.');
    }
    sleep(const Duration(milliseconds: 5));
  }
  return where();
}

void main() {
  tearDown(() async {
    Concurrency.maxWorkers = 2;
    await Concurrency.shutdown();
  });

  test('results keep the order of the tasks', () async {
    final results = await Concurrency.run<int>([
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return 1;
      },
      () => 2,
      () => 3,
    ]);
    expect(results, [1, 2, 3]);
  });

  test('tasks run on workers, at once', () async {
    final dir = Directory.systemTemp.createTempSync('daravel_conc').path;
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    // Each waits for the other, so run in turn they would both time out.
    final results = await Concurrency.run<String>([
      () => meet('$dir/a', '$dir/b'),
      () => meet('$dir/b', '$dir/a'),
    ]);
    expect(results, everyElement('daravel-compute'));
  });

  test('concurrency: 1 runs them in turn', () async {
    final watch = Stopwatch()..start();
    await Concurrency.run<void>([
      () => sleep(const Duration(milliseconds: 150)),
      () => sleep(const Duration(milliseconds: 150)),
    ], concurrency: 1);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(290));
  });

  test('more tasks than workers wait their turn', () async {
    Concurrency.maxWorkers = 2;
    final results = await Concurrency.run<int>([
      for (var i = 0; i < 8; i++) () => i * i,
    ]);
    expect(results, [0, 1, 4, 9, 16, 25, 36, 49]);
  });

  test('an error comes back with its stack, and the worker lives', () async {
    Concurrency.maxWorkers = 1;
    await expectLater(
      Concurrency.run<int>([boom]),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'boom'),
      ),
    );
    try {
      await Concurrency.run<int>([boom]);
    } on FormatException catch (_, stack) {
      expect('$stack', contains('boom'));
    }
    expect(await Concurrency.run<int>([() => 7]), [7]);
  });

  test('every task runs before the first failure is thrown', () async {
    final file = File(
      '${Directory.systemTemp.createTempSync('daravel_conc').path}/x',
    );
    addTearDown(() => file.parent.deleteSync(recursive: true));
    final path = file.path;
    await expectLater(
      Concurrency.run<void>([
        () => throw StateError('first'),
        () => throw ArgumentError('second'),
        () => File(path).writeAsStringSync('ran'),
      ], concurrency: 1),
      throwsStateError,
    );
    expect(file.readAsStringSync(), 'ran');
  });

  test('an unsendable capture is an ArgumentError here', () async {
    final port = ReceivePort();
    addTearDown(port.close);
    await expectLater(
      Concurrency.run<int>([() => port.hashCode]),
      throwsArgumentError,
    );
    expect(await Concurrency.run<int>([() => 1]), [1]);
  });

  test('an unsendable result is an error too', () async {
    await expectLater(
      Concurrency.run<ReceivePort>([ReceivePort.new]),
      throwsA(anything),
    );
    expect(await Concurrency.run<int>([() => 1]), [1]);
  });

  test('timeout gives up on the task, and the pool goes on', () async {
    Concurrency.maxWorkers = 1;
    await expectLater(
      Concurrency.run<void>([
        () => sleep(const Duration(seconds: 5)),
      ], timeout: const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );
    expect(await Concurrency.run<int>([() => 1]), [1]);
  });

  test('a task that ends its isolate does not hang the caller', () async {
    Concurrency.maxWorkers = 1;
    await expectLater(
      Concurrency.run<void>([() => Isolate.exit()]),
      throwsA(isA<RemoteError>()),
    );
    expect(await Concurrency.run<int>([() => 1]), [1]);
  });

  test('concurrency must be at least 1', () {
    expect(Concurrency.run<int>([() => 1], concurrency: 0), throwsRangeError);
  });

  test('no application in a worker', () async {
    expect(
      await Concurrency.run<bool>([() => Container.currentOrNull == null]),
      [isTrue],
    );
  });

  group('runIfLarge', () {
    test('small stays here', () async {
      expect(
        await Concurrency.runIfLarge<String>(10, where),
        isNot('daravel-compute'),
      );
    });

    test('large goes to a worker', () async {
      expect(
        await Concurrency.runIfLarge<String>(65536, where),
        'daravel-compute',
      );
    });
  });

  group('sync', () {
    test('runs in this isolate and in order', () async {
      final seen = <int>[];
      final results = await Concurrency.sync(
        () => Concurrency.run<int>([
          () {
            seen.add(1);
            return 1;
          },
          () {
            seen.add(2);
            return 2;
          },
        ]),
      );
      expect(results, [1, 2]);
      expect(seen, [1, 2]);
    });

    test('defer runs at once', () async {
      var done = false;
      await Concurrency.sync(() => Concurrency.defer([() => done = true]));
      expect(done, isTrue);
    });
  });

  test('fake counts', () async {
    await Concurrency.fake((fake) async {
      await Concurrency.run<int>([() => 1, () => 2]);
      await Concurrency.defer([() {}]);
      fake
        ..assertRanCount(2)
        ..assertDeferredCount(1);
      expect(() => fake.assertRanCount(3), throwsStateError);
    });
  });

  group('defer', () {
    test('outside a request it runs soon', () async {
      final dir = Directory.systemTemp.createTempSync('daravel_defer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/x';
      await Concurrency.defer([() => File(path).writeAsStringSync('ran')]);
      expect(File(path).existsSync(), isFalse, reason: 'not yet');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!File(path).existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(File(path).existsSync(), isTrue);
    });

    test('in a request it waits for the response', () async {
      final dir = Directory.systemTemp.createTempSync('daravel_defer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/x';
      final app = Application.configure(basePath: dir.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            web: (router) {
              router.get('/', (Request request) async {
                await Concurrency.defer([
                  () => File(path).writeAsStringSync('ran'),
                ]);
                return Response.text('ok');
              });
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final request = Request.fake();
      final response = await app.handle(request);
      expect(response.status, 200);
      expect(File(path).existsSync(), isFalse);
      final deferred = request.takeDeferred();
      expect(deferred, hasLength(1));
      await deferred.single();
      expect(File(path).readAsStringSync(), 'ran');
    });
  });

  test('an application stops the workers', () async {
    final dir = Directory.systemTemp.createTempSync('daravel_conc');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = Application.configure(basePath: dir.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    await Concurrency.run<int>([() => 1]);
    await app.shutdown();
    expect(await Concurrency.run<int>([() => 2]), [2]);
  });
}
