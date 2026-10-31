import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/jobs/send_welcome_email.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

void main() {
  late Application app;
  late TestClient client;

  Future<void> boot(Map<String, String> env) async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{
        'APP_ENV': 'testing',
        'DB_CONNECTION': 'sqlite',
        'DB_URL': 'sqlite::memory:',
        ...env,
      },
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  }

  tearDown(() => app.shutdown());

  const payload = <String, Object?>{
    'name': 'Ana',
    'email': 'ana@example.com',
    'password': 'secret-123',
    'password_confirmation': 'secret-123',
  };

  test(
    'registering dispatches UserRegistered → SendWelcomeEmail (sync)',
    () async {
      await boot({'QUEUE_CONNECTION': 'sync'});
      (await client.post('/api/auth/register', json: payload)).assertCreated();
      await app.run(() async {
        expect(await Cache.get<int>('welcome_emails'), 1);
      });
    },
  );

  test('database queue stores the job until a worker processes it', () async {
    await boot({'QUEUE_CONNECTION': 'database'});
    (await client.post('/api/auth/register', json: payload)).assertCreated();
    await app.run(() async {
      expect(await Cache.get<int>('welcome_emails'), isNull);
      final row = await DB.table('jobs').first();
      expect(row!['queue'], 'default');
      final stored = JobPayload.decode(row['payload']! as String);
      expect(stored.jobName, SendWelcomeEmail.name);
      expect(stored.data, {'user_id': 1});

      final worker = QueueWorker(Queue.manager);
      expect(await worker.run(const WorkerOptions(stopWhenEmpty: true)), 0);
      expect(worker.processed, 1);
      expect(await Cache.get<int>('welcome_emails'), 1);
      expect(await DB.table('jobs').count(), 0);
      expect(await DB.table('failed_jobs').count(), 0);
    });
  });

  test('Queue.fake captures dispatches without running them', () async {
    await boot({'QUEUE_CONNECTION': 'sync'});
    await app.run(() async {
      final fake = Queue.fake();
      await Event.dispatch(const _Nothing());
      (await client.post('/api/auth/register', json: payload)).assertCreated();
      fake.assertPushed<SendWelcomeEmail>((job) => job.userId == 1);
      fake.assertPushedOn<SendWelcomeEmail>('default');
      expect(await Cache.get<int>('welcome_emails'), isNull);
      expect(
        App.make<Schedule>().tasks.map((t) => t.name),
        contains('tokens:prune'),
      );
    });
  });
}

final class _Nothing {
  const _Nothing();
}
