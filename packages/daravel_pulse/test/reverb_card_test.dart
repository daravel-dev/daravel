import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_pulse/daravel_pulse.dart';
import 'package:test/test.dart';

void main() {
  late Application app;

  setUp(() async {
    app = Application.configure(
      basePath: Directory.systemTemp.createTempSync('pulse_reverb_').path,
    ).withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'}).create();
    await app.boot();
  });

  tearDown(() => app.shutdown());

  test('no Reverb rows (the card hidden) without Pusher clients', () async {
    expect(await app.run(() => Pulse.reverb(app.container)), isEmpty);
  });

  test('a row per isolate and application from the reverb reports', () async {
    final stats = app.container.make<ReverbStats>()
      ..connectionOpened('42')
      ..subscribed('42', 'presence-room')
      ..received('42')
      ..sent('42')
      ..sent('42')
      ..published('42', const Duration(milliseconds: 3))
      ..connectionOpened('7');
    await app.run(stats.flush);
    final rows = await app.run(() => Pulse.reverb(app.container));
    expect(rows, hasLength(2));
    final first = rows.firstWhere((r) => r['app'] == '42');
    expect(first['connections'], 1);
    expect(first['channels'], {'presence': 1});
    expect(first['received'], 1);
    expect(first['sent'], 2);
    expect(first['fanout_p95_ms'], 3);
    expect(first['worker'], isNotEmpty);
    expect(first['reported_at'], isNotNull);
    stats
      ..connectionClosed('42')
      ..connectionClosed('7')
      ..close();
  });

  test('the card links to the Reverb dashboard by its route name', () {
    final router = Router();
    expect(Pulse.reverbPath(router), isNull);
    router.get('/ops/reverb', (_) => 'page').name('reverb.index');
    expect(Pulse.reverbPath(router), '/ops/reverb');
  });
}
