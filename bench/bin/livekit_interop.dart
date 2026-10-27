// The Daravel side of bench/interop/livekit.sh: one step per run, with the
// key and secret the PHP side uses.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:daravel_livekit/daravel_livekit.dart';

const _key = 'interop-key';
const _secret = 'interop-secret-that-is-long-enough';

Future<void> main(List<String> args) async {
  final out = switch (args.first) {
    // A token PHP signed: what Daravel reads from it.
    'verify' => await () async {
      final claims = await LivekitToken.verify(
        args[1],
        apiKey: _key,
        apiSecret: _secret,
      );
      return 'identity=${claims.identity} name=${claims.name} '
          'room=${claims.video?.room} admin=${claims.video?.roomAdmin}';
    }(),
    // A token for PHP to read.
    'token' => await const LivekitToken(
      apiKey: _key,
      apiSecret: _secret,
      identity: 'teacher-1',
      name: 'Guru',
      metadata: '{"flavor":"prod"}',
      video: VideoGrant(roomJoin: true, room: 'class-7a', roomAdmin: true),
    ).toJwt(),
    // A webhook PHP signed (body file, header): the event Daravel reads.
    'receive' => await () async {
      final event = await const LivekitWebhookReceiver(
        apiKey: _key,
        apiSecret: _secret,
      ).receive(File(args[1]).readAsBytesSync(), args[2]);
      return 'event=${event.event} room=${event.room?.name}';
    }(),
    // The Authorization header LiveKit would send for a body file.
    'sign' => await LivekitToken(
      apiKey: _key,
      apiSecret: _secret,
      ttl: const Duration(minutes: 5),
      sha256: base64.encode(
        sha256.convert(File(args[1]).readAsBytesSync()).bytes,
      ),
    ).toJwt(),
    _ => 'unknown step',
  };
  stdout.writeln(out);
}
