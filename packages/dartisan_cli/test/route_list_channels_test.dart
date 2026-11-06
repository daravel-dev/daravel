import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

Application channelsApp({bool broadcasting = true}) {
  final builder = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'});
  return (broadcasting
          ? builder.withBroadcasting(
              channels: (channels) => channels
                ..channel(
                  'orders.{orderId}',
                  (user, p) => true,
                  type: 'private',
                  events: const [BroadcastEventSchema('OrderShipped')],
                )
                ..channel('chat.{room}', (user, p) => {'id': 1}),
            )
          : builder)
      .create();
}

Future<(int, String)> routeList(
  List<String> args, {
  bool broadcasting = true,
}) async {
  // ignore: close_sinks (stdout of the zone, never opened)
  final out = _Capture();
  final code = await IOOverrides.runZoned(
    () =>
        DartisanRunner(() => channelsApp(broadcasting: broadcasting))
            .execute(['route:list', ...args]),
    stdout: () => out,
  );
  return (code, '${out.buffer}');
}

void main() {
  test('route:list --channels: a table of the broadcast channels', () async {
    final (code, text) = await routeList(['--channels']);
    expect(code, 0);
    expect(text, contains('private-orders.{orderId}'));
    expect(text, contains('OrderShipped'));
    expect(text, contains('{private,presence}-chat.{room}'));
    expect(text, contains('private or presence'));
  });

  test('route:list --channels --json: describe() as JSON', () async {
    final (code, text) = await routeList(['--channels', '--json']);
    expect(code, 0);
    final json = (jsonDecode(text) as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(json.first['channel'], 'private-orders.{orderId}');
    expect(json.first['parameters'], ['orderId']);
    expect((json.first['events']! as List).single, {'name': 'OrderShipped'});
    expect(json.last['type'], isNull);
  });

  test('without broadcasting: no channels', () async {
    final (code, text) = await routeList(['--channels'], broadcasting: false);
    expect(code, 0);
    expect(text.trim(), 'No broadcast channels.');
  });
}

/// Collects what a command prints.
final class _Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
