import 'dart:io';

import 'package:daravel/src/http/graceful_server_socket.dart';
import 'package:test/test.dart';

void main() {
  test('finish completes before listening', () async {
    final socket = await GracefulServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    await socket.finish().timeout(const Duration(seconds: 2));
    await socket.finish().timeout(const Duration(seconds: 2));
  });

  test('finish closes a listened connection stream', () async {
    final socket = await GracefulServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final done = socket.drain<void>();
    await socket.finish().timeout(const Duration(seconds: 2));
    await done.timeout(const Duration(seconds: 2));
  });

  test('a second finish, called while the first is under way, completes '
      'only once the listening socket is closed', () async {
    final socket = await GracefulServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    final first = socket.finish();
    final second = socket.finish();
    expect(identical(first, second), isTrue);
    await second;
    // The port is free: the second caller did not finish early.
    final again = await ServerSocket.bind('127.0.0.1', port);
    await again.close();
    await Future.wait([first, second]);
  });

  test('stopAccepting called twice gives the same closing', () async {
    final socket = await GracefulServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    final first = socket.stopAccepting();
    await socket.stopAccepting();
    final again = await ServerSocket.bind('127.0.0.1', port);
    await again.close();
    await first;
    await socket.finish();
  });
}
