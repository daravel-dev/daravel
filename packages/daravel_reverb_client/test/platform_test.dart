import 'dart:convert';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:test/test.dart';

/// The whole library on every platform the package names, a browser too
/// (`dart test -p chrome`): it compiles there, builds a client without
/// connecting, and checks an authorization as on the VM.
void main() {
  test('a client is built without connecting; event names as Laravel Echo '
      'formats them', () async {
    final echo = Echo.reverb(
      key: 'app-key',
      host: 'wss://ws.example.com',
      path: '/reverb',
      autoConnect: false,
    );
    expect(echo.connectionState, EchoConnectionState.initialized);
    expect(echo.uri.path, '/reverb/app/app-key');
    expect(echo.formatEvent('OrderShipped'), r'App\Events\OrderShipped');
    await echo.disconnect();
  });

  test('an authorization is checked the same way: a key that is not 32 '
      'bytes is refused', () async {
    final auth = EchoAuth.custom(
      (_, _) => {
        'auth': 'k:s',
        'shared_secret': base64.encode([1, 2, 3]),
      },
    );
    await expectLater(
      auth.authorize('1.2', 'private-encrypted-orders'),
      throwsA(
        isA<EchoAuthException>().having(
          (e) => e.message,
          'message',
          'shared_secret is 3 bytes, not 32',
        ),
      ),
    );
  });
}
