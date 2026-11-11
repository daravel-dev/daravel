import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 11, 6, 12);
  late HorizonService service;

  setUp(() {
    now = DateTime.utc(2026, 11, 6, 12);
    service = HorizonService(maxPerStatus: 3, clock: () => now);
  });

  // A new uuid each time: every call is another job (the store keeps one
  // record per uuid).
  var jobs = 0;
  void record(String status, {String queue = 'a', int? ms, int ago = 0}) =>
      service.handle('record', {
        'job': jsonEncode(
          RecordedJob(
            uuid: 'u${jobs++}',
            name: 'mark',
            queue: queue,
            status: status,
            at: now.millisecondsSinceEpoch - ago,
            durationMs: ms,
          ).toJson(),
        ),
      });

  List<Object?> recent(String status) =>
      jsonDecode(service.handle('recent', {'status': status})! as String)
          as List<Object?>;

  test('recent jobs per status, newest first, at most maxPerStatus', () {
    for (var i = 0; i < 5; i++) {
      record('completed', ms: i, ago: 10 - i);
    }
    record('failed');
    final completed = recent('completed');
    expect(completed, hasLength(3));
    expect((completed.first! as Map)['duration_ms'], 4);
    expect(recent('failed'), hasLength(1));
    expect(service.stats(), {'completed': 3, 'failed': 1, 'silenced': 0});
  });

  test('rates: jobs a second and average run time over the last minute', () {
    service = HorizonService(clock: () => now);
    record('completed', ms: 100);
    record('completed', ms: 300);
    record('failed');
    record('completed', ms: 900, ago: 61000); // older than a minute
    record('completed', queue: 'b', ms: 5);
    final a = service.rates('a');
    expect(a['per_second'], closeTo(3 / 60, 1e-9));
    expect(a['avg_ms'], 200);
    expect(service.rates('c'), {'per_second': 0.0, 'avg_ms': null});
  });

  test('completed jobs leave after the retention, failed ones later', () {
    record('completed');
    record('failed');
    now = now.add(const Duration(minutes: 61));
    record('completed');
    record('failed');
    expect(recent('completed'), hasLength(1));
    expect(recent('failed'), hasLength(2));
  });

  test('a busy coordinator may drop records, never the reads', () {
    expect(service.priority, CoordinatorPriority.normal);
    expect(
      service.priorityFor('record', const <String, Object?>{}),
      CoordinatorPriority.bulk,
    );
    for (final op in const ['recent', 'rates']) {
      expect(
        service.priorityFor(op, const <String, Object?>{}),
        CoordinatorPriority.normal,
      );
    }
  });

  void recordJob(
    String uuid, {
    String status = 'completed',
    String name = 'mark',
    String queue = 'a',
    List<String> tags = const [],
    int? ms,
  }) => service.handle('record', {
    'job': jsonEncode(
      RecordedJob(
        uuid: uuid,
        name: name,
        queue: queue,
        status: status,
        at: now.millisecondsSinceEpoch,
        tags: tags,
        durationMs: ms,
      ).toJson(),
    ),
  });

  test('a job by uuid, silenced jobs, and paging of recent', () {
    recordJob('j1');
    recordJob('j2', status: 'silenced');
    recordJob('j3', status: 'failed');
    expect(
      (jsonDecode(service.handle('job', {'uuid': 'j2'})! as String)
          as Map)['status'],
      'silenced',
    );
    expect(service.handle('job', {'uuid': 'nope'}), isNull);
    expect(recent('silenced'), hasLength(1));
    recordJob('j4');
    final page = jsonDecode(
      service.handle('recent', {
            'status': 'completed',
            'limit': 1,
            'offset': 1,
          })!
          as String,
    ) as List<Object?>;
    expect((page.single! as Map)['uuid'], 'j1');
  });

  test('monitored tags keep their jobs; unmonitor drops them', () {
    service.handle('monitor', {'tag': 'User:1'});
    recordJob('t1', tags: ['User:1']);
    recordJob('t2', tags: ['User:2']);
    recordJob('t3', status: 'failed', tags: ['User:1']);
    final monitored =
        jsonDecode(service.handle('monitored', {})! as String) as List<Object?>;
    expect(monitored, [
      {'tag': 'User:1', 'count': 2},
    ]);
    final tagged = jsonDecode(
      service.handle('tagged', {'tag': 'User:1'})! as String,
    ) as List<Object?>;
    expect([for (final j in tagged) (j! as Map)['uuid']], ['t3', 't1']);
    service.handle('unmonitor', {'tag': 'User:1'});
    expect(jsonDecode(service.handle('monitored', {})! as String), isEmpty);
    expect(
      jsonDecode(service.handle('tagged', {'tag': 'User:1'})! as String),
      isEmpty,
    );
  });

  test('summary and metric snapshots per job and queue', () {
    recordJob('s1', name: 'mail', queue: 'q', ms: 10);
    recordJob('s2', name: 'mail', queue: 'q', ms: 30);
    recordJob('s3', status: 'failed', name: 'sms', queue: 'q');
    expect(jsonDecode(service.handle('summary', {})! as String), {
      'jobs_per_minute': 3,
      'jobs_past_hour': 3,
      'failed_past_week': 1,
    });
    service.handle('snapshot', {});
    now = now.add(const Duration(minutes: 5));
    service.handle('snapshot', {});
    final metrics = jsonDecode(
      service.handle('metrics', {})! as String,
    ) as Map<String, Object?>;
    final mail = (metrics['jobs']! as Map)['mail']! as List<Object?>;
    expect(mail, hasLength(2));
    expect((mail.first! as Map)['count'], 2);
    expect((mail.first! as Map)['avg_ms'], 20);
    expect((mail.last! as Map)['count'], 0, reason: 'nothing since');
    expect(
      (((metrics['queues']! as Map)['q']! as List).first! as Map)['count'],
      3,
    );
  });
}
