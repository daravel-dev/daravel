import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

Application serverApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'memory',
        })
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (r) => r.get('/secret', (Request q) => Response.text('app')),
        )
        .withHorizon(createApp: serverApp)
        .create();

void main() {
  test('horizon --dashboard addresses', () {
    expect(HorizonCommand.parseAddress(':8090'), ('127.0.0.1', 8090));
    expect(HorizonCommand.parseAddress('0.0.0.0:9000'), ('0.0.0.0', 9000));
    expect(HorizonCommand.parseAddress('8090'), isNull);
    expect(HorizonCommand.parseAddress(':99999'), isNull);
  });

  test(
    'the dashboard server answers Horizon\'s routes and nothing else',
    () async {
      final app = serverApp();
      await app.boot();
      addTearDown(app.shutdown);
      final engine = await HorizonCommand.serveDashboard(
        app,
        host: '127.0.0.1',
        port: 0,
      );
      addTearDown(engine.stop);
      final client = HttpClient();
      addTearDown(client.close);
      Future<(int, String)> get(String path) async {
        final response = await (await client.get(
          '127.0.0.1',
          engine.port!,
          path,
        )).close();
        return (response.statusCode, await utf8.decodeStream(response));
      }

      final (status, body) = await get('/horizon/api/stats');
      expect(status, 200, reason: body);
      expect(jsonDecode(body), containsPair('status', 'inactive'));
      expect((await get('/horizon')).$1, 200);
      expect((await get('/secret')).$1, 404, reason: 'not the app\'s routes');
    },
  );
}
