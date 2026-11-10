import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// A connection that fails to open, or a cluster slot map that cannot be
/// read, is shared by every command waiting on it, each in a request of
/// its own: each must get the error (Review #147).
void main() {
  final uncaught = <Object>[];
  setUp(uncaught.clear);

  Future<int> closedPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// [call] from two request scopes at once: what each got, within a few
  /// seconds (a hang fails the test).
  Future<List<String>> both(Future<Object?> Function() call) => Future.wait([
    for (var i = 0; i < 2; i++)
      Container().runScoped('request', (_) async {
        try {
          await call();
          return 'value';
        } on Object catch (error) {
          return error.runtimeType.toString();
        }
      }, onUncaughtError: (error, _) => uncaught.add(error)),
  ]).timeout(const Duration(seconds: 10));

  test('a connection that fails to open reaches every command waiting for '
      'it', () async {
    final port = await closedPort();
    final client = RedisClient(
      RedisConnectionConfig.fromUrl('redis://127.0.0.1:$port'),
    );
    addTearDown(client.close);
    final answers = await both(() => client.command(['PING']));
    expect(answers, everyElement(isNot('value')));
    expect(answers[0], answers[1], reason: 'the same error for both');
    expect(uncaught, isEmpty);
  });

  test('a cluster slot map that cannot be read reaches every command '
      'waiting for it', () async {
    final a = await closedPort();
    final b = await closedPort();
    final client = RedisClient(
      RedisConnectionConfig.fromUrl(
        'redis+cluster://127.0.0.1:$a,127.0.0.1:$b',
      ),
    );
    addTearDown(client.close);
    expect(client, isA<RedisClusterClient>());
    final answers = await both(() => client.command(['GET', 'k']));
    expect(answers, everyElement(isNot('value')));
    expect(answers[0], answers[1], reason: 'the same error for both');
    expect(uncaught, isEmpty);
  });
}
