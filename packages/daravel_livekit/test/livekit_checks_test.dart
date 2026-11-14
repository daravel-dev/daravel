import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_livekit/daravel_livekit.dart';
import 'package:test/test.dart';

const _key = 'APIkey';
const _secret = 'a-secret-long-enough-for-hs256-signing';

/// Checks on what LiveKit tokens and webhooks carry: a token must have
/// `exp` (LiveKit's server SDKs require it), the key and the identity must
/// be usable, a webhook checked for age needs its id and `created_at`, the
/// replay check remembers an event as long as it is accepted, and a field
/// of the wrong type is a refusal, not a type error.
void main() {
  tearDown(Clock.restore);
  final t0 = DateTime.utc(2026, 11, 14, 7, 30);
  final epoch = t0.millisecondsSinceEpoch ~/ 1000;

  Future<String> webhookToken(List<int> body, {Duration? ttl}) => LivekitToken(
    apiKey: _key,
    apiSecret: _secret,
    ttl: ttl ?? const Duration(minutes: 5),
    sha256: base64.encode(sha256.convert(body).bytes),
  ).toJwt();

  group('tokens', () {
    test('a token without exp is refused, as by LiveKit\'s SDKs', () async {
      Clock.fake(t0);
      final noExp = await JwtCodec.hs256(_secret)
          .sign({'iss': _key, 'sub': 'u-1'});
      await expectLater(
        LivekitToken.verify(noExp, apiKey: _key, apiSecret: _secret),
        throwsA(isA<JwtException>()),
      );
      final withExp = await JwtCodec.hs256(_secret)
          .sign({'iss': _key, 'sub': 'u-1', 'exp': epoch + 60});
      final claims = await LivekitToken.verify(
        withExp,
        apiKey: _key,
        apiSecret: _secret,
      );
      expect(claims.identity, 'u-1');
    });

    test('an empty or blank API key is refused before signing or '
        'verifying', () async {
      for (final key in ['', '  ']) {
        await expectLater(
          LivekitToken(apiKey: key, apiSecret: _secret, identity: 'u').toJwt(),
          throwsStateError,
          reason: '"$key"',
        );
        await expectLater(
          LivekitToken.verify('a.b.c', apiKey: key, apiSecret: _secret),
          throwsStateError,
          reason: '"$key"',
        );
        await expectLater(
          LivekitWebhookReceiver(
            apiKey: key,
            apiSecret: _secret,
          ).receive(utf8.encode('{}'), 'Bearer x'),
          throwsStateError,
          reason: '"$key"',
        );
      }
    });

    test('an identity with a control character is refused', () async {
      for (final identity in ['u\n1', 'u\u00001', 'u\r', 'u\u007f', '\t']) {
        await expectLater(
          LivekitToken(
            apiKey: _key,
            apiSecret: _secret,
            identity: identity,
          ).toJwt(),
          throwsArgumentError,
          reason: jsonEncode(identity),
        );
      }
      // Other text, spaces and non-ASCII included, is an identity.
      await const LivekitToken(
        apiKey: _key,
        apiSecret: _secret,
        identity: 'Ana María 7',
      ).toJwt();
    });

    test('claims of the wrong type are a JwtException', () async {
      for (final (claims, read)
          in <(Map<String, Object?>, Object? Function(LivekitClaims))>[
            ({'video': 'all'}, (c) => c.video),
            (
              {
                'video': {'roomJoin': 'yes'},
              },
              (c) => c.video,
            ),
            (
              {
                'video': {'room': 7},
              },
              (c) => c.video,
            ),
            (
              {
                'video': {'canPublishSources': 'camera'},
              },
              (c) => c.video,
            ),
            ({'sub': 7}, (c) => c.identity),
            ({'name': <Object?>[]}, (c) => c.name),
            ({'sha256': 1}, (c) => c.sha256),
          ]) {
        expect(
          () => read(LivekitClaims(claims)),
          throwsA(isA<JwtException>()),
          reason: '$claims',
        );
      }
    });
  });

  group('webhooks', () {
    const receiver = LivekitWebhookReceiver(apiKey: _key, apiSecret: _secret);
    List<int> body(Map<String, Object?> json) => utf8.encode(jsonEncode(json));

    test('a webhook token without exp is refused', () async {
      Clock.fake(t0);
      final payload = body({
        'event': 'room_started',
        'id': 'EV_1',
        'createdAt': '$epoch',
      });
      final noExp = await JwtCodec.hs256(_secret).sign({
        'iss': _key,
        'sha256': base64.encode(sha256.convert(payload).bytes),
      });
      await expectLater(
        receiver.receive(payload, noExp),
        throwsA(isA<LivekitWebhookException>()),
      );
    });

    test('with maxAge, an event without an id or a readable created_at is '
        'refused; without maxAge it is taken', () async {
      Clock.fake(t0);
      for (final json in <Map<String, Object?>>[
        {'event': 'room_started', 'createdAt': '$epoch'},
        {'event': 'room_started', 'id': '', 'createdAt': '$epoch'},
        {'event': 'room_started', 'id': 'EV_1'},
        {'event': 'room_started', 'id': 'EV_1', 'createdAt': '0'},
        {'event': 'room_started', 'id': 'EV_1', 'createdAt': 'soon'},
        {
          'event': 'room_started',
          'id': 'EV_1',
          'createdAt': '99999999999999999',
        },
      ]) {
        final payload = body(json);
        final token = await webhookToken(payload);
        await expectLater(
          receiver.receive(payload, token),
          throwsA(isA<LivekitWebhookException>()),
          reason: '$json',
        );
        const unchecked = LivekitWebhookReceiver(
          apiKey: _key,
          apiSecret: _secret,
          maxAge: null,
        );
        expect((await unchecked.receive(payload, token)).event, 'room_started');
      }
      // A number past any int in the raw JSON is unreadable, not a 500.
      final huge = utf8.encode(
        '{"event":"room_started","id":"EV_1","createdAt":1e400}',
      );
      await expectLater(
        receiver.receive(huge, await webhookToken(huge)),
        throwsA(isA<LivekitWebhookException>()),
      );
    });

    test(
      'an event field of the wrong type is a LivekitWebhookException',
      () async {
        Clock.fake(t0);
        for (final name in ['track', 'egress_info', 'ingressInfo']) {
          final payload = body({
            'event': 'track_published',
            'id': 'EV_1',
            'createdAt': '$epoch',
            name: 'not an object',
          });
          final event = await receiver.receive(
            payload,
            await webhookToken(payload),
          );
          expect(
            () => [event.track, event.egressInfo, event.ingressInfo],
            throwsA(isA<LivekitWebhookException>()),
            reason: name,
          );
        }
      },
    );

    test(
      'the replay check remembers an event as long as it is accepted',
      () async {
        // Accepted from created_at - 30 s to created_at + 5 min + 30 s: an
        // event dated 25 s ahead, first received at t0, is still accepted at
        // t0 + 335 s, and must still be known then.
        Clock.fake(t0);
        final app = Application.configure(basePath: '.')
            .withEnv(const {
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'LIVEKIT_API_KEY': _key,
              'LIVEKIT_API_SECRET': _secret,
            })
            .withLivekit()
            .withRouting(
              apiPrefix: '',
              api: (router) => router.post('/hook', (request) async {
                final event = await Livekit.webhook(request);
                return {'id': event.id};
              }),
            )
            .create();
        await app.boot();
        addTearDown(app.shutdown);
        final payload = body({
          'event': 'room_finished',
          'id': 'EV_9',
          'createdAt': '${epoch + 25}',
        });
        final token = await webhookToken(
          payload,
          ttl: const Duration(minutes: 10),
        );
        Future<int> deliver() async => (await app.handle(
          Request.fake(
            method: 'POST',
            path: '/hook',
            body: utf8.decode(payload),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            },
          ),
        )).status;
        expect(await deliver(), 200);
        Clock.travel(const Duration(seconds: 335));
        expect(await deliver(), 401, reason: 'a replay inside the window');
        expect(
          LivekitWebhookReceiver.acceptance(const Duration(minutes: 5)),
          const Duration(seconds: 360),
        );
      },
    );
  });
}
