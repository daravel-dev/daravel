import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A scoped binding: one instance per scope.
final class Marker {}

final class FakeUser implements Authenticatable {
  FakeUser(this.authIdentifier);
  @override
  final Object authIdentifier;
  @override
  String get authIdentifierName => 'id';
  @override
  String? get authPassword => null;
  @override
  String get authPasswordName => 'password';
  @override
  String? get rememberToken => null;
}

/// Records the context it was dispatched with.
final class CaptureContext extends Job {
  const CaptureContext();
  static const String jobName_ = 'capture-context';
  static Map<String, Object?>? seen;
  static Map<String, Object?>? seenHidden;
  @override
  String get jobName => jobName_;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    seen = Context.all();
    seenHidden = Context.allHidden();
  }
}

void main() {
  late Application app;
  final at = DateTime.utc(2026, 10, 24, 3, 0);

  setUp(() async {
    CaptureContext.seen = null;
    CaptureContext.seenHidden = null;
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'sync',
        })
        .withJobs([
          JobDefinition(CaptureContext.jobName_, (_) => const CaptureContext()),
        ])
        .withBindings((c) => c.scoped<Marker>((_) => Marker()))
        .withAuth(
          (auth) => auth.register(
            'token',
            ClosureGuard<FakeUser>(name: 'token', resolver: (_) => null),
          ),
        )
        .create();
    await app.boot();
  });

  tearDown(() => app.shutdown());

  test('a task does not see the context an earlier task added', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      Map<String, Object?>? seen;
      Map<String, Object?>? seenHidden;
      schedule
          .call(() {
            Context.add('tenant', 7);
            Context.addHidden('secret', 'x');
          })
          .everyMinute()
          .named('first');
      schedule
          .call(() {
            seen = Context.all();
            seenHidden = Context.allHidden();
          })
          .everyMinute()
          .named('second');
      final results = await app.scheduler().run(at);
      expect(results.map((r) => r.ran), [true, true]);
      expect(seen, isEmpty);
      expect(seenHidden, isEmpty);
    });
  });

  test('a job dispatched by a task does not carry an earlier task\'s '
      'context', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      schedule
          .call(() {
            Context.add('tenant', 7);
            Context.addHidden('secret', 'x');
          })
          .everyMinute()
          .named('first');
      schedule.job(const CaptureContext()).everyMinute();
      final results = await app.scheduler().run(at);
      expect(results.map((r) => r.ran), [true, true]);
      expect(CaptureContext.seen, isNotNull, reason: 'the job ran');
      expect(CaptureContext.seen, isEmpty);
      expect(CaptureContext.seenHidden, isEmpty);
    });
  });

  test('a task does not see the log context an earlier task added', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      Map<String, Object?>? seen;
      schedule
          .call(() => Log.withContext({'run': 'first'}))
          .everyMinute()
          .named('first');
      schedule
          .call(() => seen = Map.of(Log.logger.scopeContext))
          .everyMinute()
          .named('second');
      await app.scheduler().run(at);
      expect(seen, isEmpty);
      expect(Log.logger.sharedContext, isNot(contains('run')));
    });
  });

  test('a task does not see the user an earlier task set', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      Authenticatable? inFirst;
      Authenticatable? inSecond = FakeUser(0);
      schedule
          .call(() async {
            Auth.setUser(FakeUser(1));
            inFirst = await Auth.user();
          })
          .everyMinute()
          .named('first');
      schedule
          .call(() async => inSecond = await Auth.user())
          .everyMinute()
          .named('second');
      final results = await app.scheduler().run(at);
      expect(results.map((r) => r.error), [null, null]);
      expect(inFirst?.authIdentifier, 1, reason: 'the user was set');
      expect(inSecond, isNull);
    });
  });

  test('scoped instances: one per task, shared by its hooks', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      final first = <String, Marker>{};
      final second = <String, Marker>{};
      schedule
          .call(() => first['action'] = App.make<Marker>())
          .everyMinute()
          .before(() => first['before'] = App.make<Marker>())
          .after(() => first['after'] = App.make<Marker>())
          .named('first');
      schedule
          .call(() => second['action'] = App.make<Marker>())
          .everyMinute()
          .before(() => second['before'] = App.make<Marker>())
          .after(() => second['after'] = App.make<Marker>())
          .named('second');
      await app.scheduler().run(at);
      expect(first.keys, ['before', 'action', 'after']);
      expect(second.keys, ['before', 'action', 'after']);
      expect(first.values.toSet(), hasLength(1));
      expect(second.values.toSet(), hasLength(1));
      expect(identical(first['action'], second['action']), isFalse);
      expect(
        identical(first['action'], App.make<Marker>()),
        isFalse,
        reason: 'the surrounding scope keeps its own instance',
      );
    });
  });

  test('a failing task: its onFailure hook runs in its scope, the next task '
      'gets a fresh one', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      Marker? inAction;
      Marker? inFailure;
      Object? tenantInFailure;
      Marker? inSecond;
      Map<String, Object?>? contextInSecond;
      schedule
          .call(() {
            inAction = App.make<Marker>();
            Context.add('tenant', 7);
            throw StateError('boom');
          })
          .everyMinute()
          .onFailure((_) {
            inFailure = App.make<Marker>();
            tenantInFailure = Context.get<Object>('tenant');
          })
          .named('broken');
      schedule
          .call(() {
            inSecond = App.make<Marker>();
            contextInSecond = Context.all();
          })
          .everyMinute()
          .named('second');
      final results = await app.scheduler().run(at);
      expect(results.first.error, isA<StateError>());
      expect(results.last.ran, isTrue);
      expect(inAction, isNotNull);
      expect(identical(inFailure, inAction), isTrue);
      expect(tenantInFailure, 7);
      expect(identical(inSecond, inAction), isFalse);
      expect(contextInSecond, isEmpty);
    });
  });

  test('a scheduler without a container runs tasks in the caller\'s '
      'scope, as before', () async {
    await app.run(() async {
      final schedule = Schedule();
      final markers = <Marker>[];
      schedule.call(() => markers.add(App.make<Marker>())).everyMinute();
      schedule.call(() => markers.add(App.make<Marker>())).everyMinute();
      final scheduler = Scheduler(schedule, environment: 'testing');
      final results = await scheduler.run(at);
      expect(results.map((r) => r.ran), [true, true]);
      expect(markers, hasLength(2));
      expect(identical(markers[0], App.make<Marker>()), isTrue);
      expect(identical(markers[1], App.make<Marker>()), isTrue);
    });
  });

  test('the overlap lock is released after a task ran in its scope, also '
      'when it failed', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      var runs = 0;
      var failures = 0;
      schedule
          .call(() => runs++)
          .everyMinute()
          .withoutOverlapping()
          .named('locked');
      schedule
          .call(() {
            failures++;
            throw StateError('boom');
          })
          .everyMinute()
          .withoutOverlapping()
          .named('locked-failing');
      final scheduler = app.scheduler();
      final first = await scheduler.run(at);
      final second = await scheduler.run(at.add(const Duration(minutes: 1)));
      expect(first.map((r) => r.skipped), [null, null]);
      expect(second.map((r) => r.skipped), [null, null]);
      expect(runs, 2);
      expect(failures, 2);
      for (final name in ['locked', 'locked-failing']) {
        final lock = Cache.store('process')
            .lock('schedule:$name:* * * * *', owner: 'probe');
        expect(await lock.acquire(), isTrue, reason: '$name was released');
        await lock.release();
      }
    });
  });
}
