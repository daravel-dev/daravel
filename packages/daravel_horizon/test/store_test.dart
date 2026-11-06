import 'dart:convert';

import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 11, 6, 12);
  late HorizonService service;

  setUp(() {
    now = DateTime.utc(2026, 11, 6, 12);
    service = HorizonService(maxPerStatus: 3, clock: () => now);
  });

  void record(String status, {String queue = 'a', int? ms, int ago = 0}) =>
      service.handle('record', {
        'job': jsonEncode(
          RecordedJob(
            uuid: 'u${now.microsecond}$status$ago',
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
    expect(service.stats(), {'completed': 3, 'failed': 1});
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
}
