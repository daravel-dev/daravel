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
}
