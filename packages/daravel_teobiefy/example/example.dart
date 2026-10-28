import 'package:daravel_teobiefy/daravel_teobiefy.dart';

void main() async {
  // Generate an ephemeral X25519 keypair for secure handshake
  final serverPair = await TeobiefyCrypto.newKeyPair();
  final serverPub = await serverPair.extractPublicKey();

  print(
    'Teobiefy Ephemeral Server Public Key ready (${serverPub.bytes.length} bytes)',
  );

  // Configuration for teobiefy session lifecycle
  const config = TeobiefyConfig(
    sessionTtl: Duration(minutes: 30),
    strictPayload: true,
  );

  print('Session TTL: ${config.sessionTtl.inMinutes} minutes');
  print('Strict payload enforcement: ${config.strictPayload}');
}
