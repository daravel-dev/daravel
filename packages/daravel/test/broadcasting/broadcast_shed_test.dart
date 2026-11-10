import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// The coordinator of one isolate, but the broadcast publish fails with
/// [failure] while one is set: as under a flood, where a worker's channel
/// sheds bulk calls or the coordinator does not answer in time.
final class _FailingBroadcasts implements TypedCoordinatorChannel {
  _FailingBroadcasts(this._inner);

  final LocalCoordinatorChannel _inner;
  Object? failure;

  @override
  StateScope get scope => _inner.scope;

  @override
  bool get isRemote => _inner.isRemote;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final error = failure;
    if (error != null && service == 'broadcast' && op == 'publish') {
      throw error;
    }
    return _inner.call(service, op, args, timeout: timeout);
  }

  @override
  Future<Object?> callTyped(
    String service,
    Object message, {
    Duration timeout = const Duration(seconds: 1),
  }) => _inner.callTyped(service, message, timeout: timeout);
}

final class CreateNotesTable extends Migration {
  const CreateNotesTable();

  @override
  String get name => '2026_11_11_000000_create_notes_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('notes', (t) {
    t.id();
    t.string('text');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.drop('notes');
}

void main() {
  late Application app;
  late TestClient client;
  late _FailingBroadcasts channel;
  final shed = <BroadcastShed>[];

  setUp(() async {
    shed.clear();
    channel = _FailingBroadcasts(
      LocalCoordinatorChannel(createStandardCoordinator()),
    );
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_shed_')
                  .path,
            )
            .withEnv(const {
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'REVERB_APP_ID': '42',
              'REVERB_APP_KEY': 'daravel-key',
              'REVERB_APP_SECRET': 'daravel-secret',
              'METRICS_ENABLED': 'true',
            })
            .withLogLevel(LogLevel.critical)
            .withMigrations(const [CreateNotesTable()])
            .withBroadcasting()
            .withEvents((events) => events.listen<BroadcastShed>(shed.add))
            .withRouting(
              api: (r) => r
                ..post('/send', (request) async {
                  await Broadcast.send('news', ['news'], {'n': 1});
                  return Response.noContent();
                })
                ..post('/commit', (request) async {
                  await DB.transaction(() async {
                    await DB.table('notes').insert({'text': 'kept'});
                    await Broadcast.send('news', ['news'], {'n': 2});
                  });
                  return Response.noContent();
                }),
            )
            .create()
          ..coordinator = channel;
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  Future<String> metrics() => app.run(() => App.make<AppMetrics>().render());

  test('a broadcast the coordinator sheds does not fail the request: '
      'counted, logged and told as BroadcastShed', () async {
    channel.failure = const CoordinatorOverloaded('broadcast');
    final response = await client.post('/api/send');
    expect(response.status, 204);
    expect(
      await metrics(),
      contains('broadcast_shed_total{reason="overloaded"} 1'),
    );
    expect(shed, hasLength(1));
    expect(shed.single.event, 'news');
    expect(shed.single.channels, ['news']);
    expect(shed.single.reason, 'overloaded');
  });

  test('a coordinator that does not answer in time: the same, reason '
      'timeout', () async {
    channel.failure = CoordinatorTimeoutException(
      'broadcast',
      const Duration(seconds: 1),
    );
    expect((await client.post('/api/send')).status, 204);
    expect(shed.single.reason, 'timeout');
    expect(
      await metrics(),
      contains('broadcast_shed_total{reason="timeout"} 1'),
    );
  });

  test('after commit: the data is committed and the request answers', () async {
    channel.failure = const CoordinatorOverloaded('broadcast');
    expect((await client.post('/api/commit')).status, 204);
    final rows = await app.run(() => DB.table('notes').get());
    expect(rows.map((r) => r['text']), ['kept']);
    expect(shed, hasLength(1));
  });

  test('inside a job it is rethrown, so the job is retried', () async {
    channel.failure = const CoordinatorOverloaded('broadcast');
    await expectLater(
      app.container.runScoped(
        'job',
        (_) => Broadcast.send('news', ['news'], {'n': 3}),
      ),
      throwsA(isA<CoordinatorOverloaded>()),
    );
    expect(shed, isEmpty);
  });

  test('any other error still fails the request', () async {
    channel.failure = StateError('a programming error');
    final response = await client.post('/api/send');
    expect(response.status, 500);
    expect(shed, isEmpty);
  });
}
