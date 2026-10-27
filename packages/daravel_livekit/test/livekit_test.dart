import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_livekit/daravel_livekit.dart';
import 'package:test/test.dart';

const _key = 'APIkey';
const _secret = 'a-secret-long-enough-for-hs256-signing';

/// The JSON payload of [jwt], unverified.
Map<String, Object?> _payload(String jwt) => jsonDecode(
  utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1]))),
) as Map<String, Object?>;

void main() {
  twirpRetryTests();
  tearDown(Clock.restore);

  group('tokens', () {
    test('claims as LiveKit SDKs write them', () async {
      Clock.fake(DateTime.utc(2026, 10, 27, 7, 30));
      final jwt = await const LivekitToken(
        apiKey: _key,
        apiSecret: _secret,
        identity: 'u-7',
        name: 'Ana',
        metadata: '{"flavor":"prod"}',
        ttl: Duration(hours: 2),
        video: VideoGrant(roomJoin: true, room: 'class-7a', roomAdmin: false),
      ).toJwt();
      final now =
          DateTime.utc(2026, 10, 27, 7, 30).millisecondsSinceEpoch ~/ 1000;
      expect(_payload(jwt), {
        'iat': now,
        'sub': 'u-7',
        'jti': 'u-7',
        'exp': now + 7200,
        'nbf': now,
        'iss': _key,
        'name': 'Ana',
        'metadata': '{"flavor":"prod"}',
        'video': {'roomJoin': true, 'roomAdmin': false, 'room': 'class-7a'},
      });
      final claims = await LivekitToken.verify(
        jwt,
        apiKey: _key,
        apiSecret: _secret,
      );
      expect(claims.identity, 'u-7');
      expect(claims.video?.room, 'class-7a');
      expect(claims.video?.roomAdmin, isFalse);
      expect(claims.expiresAt, DateTime.utc(2026, 10, 27, 9, 30));
    });

    test('joining needs an identity; a ttl must be positive', () {
      expect(
        () => const LivekitToken(
          apiKey: _key,
          apiSecret: _secret,
          video: VideoGrant(roomJoin: true, room: 'r'),
        ).claims,
        throwsStateError,
      );
      expect(
        () => const LivekitToken(
          apiKey: _key,
          apiSecret: _secret,
          identity: 'u',
          ttl: Duration.zero,
        ).claims,
        throwsArgumentError,
      );
    });

    test(
      'verification refuses another secret, issuer or an expired token',
      () async {
        Clock.freeze();
        final jwt = await const LivekitToken(
          apiKey: _key,
          apiSecret: _secret,
          identity: 'u',
          ttl: Duration(minutes: 5),
        ).toJwt();
        await expectLater(
          LivekitToken.verify(jwt, apiKey: _key, apiSecret: '${_secret}x'),
          throwsA(isA<JwtException>()),
        );
        await expectLater(
          LivekitToken.verify(jwt, apiKey: 'other', apiSecret: _secret),
          throwsA(isA<JwtException>()),
        );
        Clock.travel(const Duration(minutes: 10));
        await expectLater(
          LivekitToken.verify(jwt, apiKey: _key, apiSecret: _secret),
          throwsA(isA<JwtException>()),
        );
      },
    );

    test('grants merge what the other sets, and send only what is set', () {
      const base = VideoGrant(roomJoin: true, room: 'r', canPublish: true);
      final merged = base.merge(const VideoGrant(roomAdmin: true));
      expect(merged.toJson(), {
        'roomJoin': true,
        'roomAdmin': true,
        'room': 'r',
        'canPublish': true,
      });
      expect(const VideoGrant().toJson(), isEmpty);
      expect(
        const LivekitToken(
          apiKey: _key,
          apiSecret: _secret,
          identity: 'u',
        ).withGrant(const VideoGrant(roomList: true)).claims['video'],
        {'roomList': true},
      );
    });
  });

  group('webhooks', () {
    const receiver = LivekitWebhookReceiver(apiKey: _key, apiSecret: _secret);
    final body = utf8.encode(
      '{"event":"participant_joined","id":"EV_1","createdAt":"1761550200",'
      '"room":{"sid":"RM_1","name":"class-7a","maxParticipants":50},'
      '"participant":{"sid":"PA_1","identity":"u-7","state":"ACTIVE"}}',
    );

    Future<String> signed(List<int> body, {String secret = _secret}) =>
        LivekitToken(
          apiKey: _key,
          apiSecret: secret,
          ttl: const Duration(minutes: 5),
          sha256: base64.encode(sha256.convert(body).bytes),
        ).toJwt();

    test('a signed body becomes an event', () async {
      for (final header in [
        await signed(body),
        'Bearer ${await signed(body)}',
      ]) {
        final event = await receiver.receive(body, header);
        expect(event.event, 'participant_joined');
        expect(event.id, 'EV_1');
        expect(event.createdAt, DateTime.utc(2025, 10, 27, 7, 30));
        expect(event.room?.name, 'class-7a');
        expect(event.room?.maxParticipants, 50);
        expect(event.participant?.identity, 'u-7');
        expect(event.participant?.state, 'ACTIVE');
      }
    });

    test('an empty secret verifies nothing', () async {
      // HS256 over an empty key would accept a token signed with an empty
      // key: anyone knowing the API key (the `iss` of every client token)
      // could sign webhooks for a server whose secret is unset. That is the
      // server's misconfiguration (a 500), not LiveKit's (a 401).
      const unset = LivekitWebhookReceiver(apiKey: _key, apiSecret: '');
      // The core codec refuses an empty key too, so the forgery is signed
      // with the real secret: the receiver must refuse before it looks at
      // the token at all.
      final forged = await signed(body);
      await expectLater(
        unset.receive(body, forged),
        throwsA(isA<StateError>()),
      );
      expect(
        () => JwtCodec.hs256(''),
        throwsArgumentError,
        reason: 'no empty-key codec to be fooled with',
      );
      await expectLater(
        LivekitToken.verify(forged, apiKey: _key, apiSecret: ''),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        const LivekitToken(apiKey: _key, apiSecret: '').toJwt(),
        throwsA(isA<StateError>()),
      );
    });

    test('anything else is refused with 401', () async {
      final tampered = utf8.encode(
        utf8.decode(body).replaceFirst('u-7', 'u-8'),
      );
      for (final (data, header) in [
        (body, null),
        (body, ''),
        (tampered, await signed(body)),
        (body, await signed(body, secret: '${_secret}x')),
        (body, 'not-a-jwt'),
      ]) {
        await expectLater(
          receiver.receive(data, header),
          throwsA(
            isA<LivekitWebhookException>().having(
              (e) => e.status,
              'status',
              401,
            ),
          ),
          reason: '$header',
        );
      }
    });
  });

  group('room service', () {
    late HttpClientFactory http;
    late HttpFake fake;
    late RoomServiceClient rooms;

    setUp(() {
      http = HttpClientFactory();
      fake = http.fake({
        '*/twirp/livekit.RoomService/ListRooms': Http.response({
          'rooms': [
            {
              'sid': 'RM_1',
              'name': 'class-7a',
              'max_participants': 50,
              'creation_time': '1761550200',
              'num_participants': 3,
            },
          ],
        }),
        '*/twirp/livekit.RoomService/GetParticipant': Http.response({
          'code': 'not_found',
          'msg': 'participant does not exist',
        }, 404),
        '*': Http.response(<String, Object?>{}),
      });
      rooms = RoomServiceClient(
        'wss://lk.example.test/',
        apiKey: _key,
        apiSecret: _secret,
        http: http,
      );
    });

    Future<Map<String, Object?>> grantOf(ClientRequest request) async =>
        (await LivekitToken.verify(
              request.header('authorization')!.substring(7),
              apiKey: _key,
              apiSecret: _secret,
            )).claims['video']!
            as Map<String, Object?>;

    test('Twirp calls carry only the grant they need', () async {
      expect(rooms.url, 'https://lk.example.test');
      final listed = await rooms.listRooms(['class-7a']);
      expect(listed.single.name, 'class-7a');
      expect(listed.single.maxParticipants, 50);
      expect(listed.single.createdAt, DateTime.utc(2025, 10, 27, 7, 30));
      await rooms.createRoom('class-7a', maxParticipants: 50, metadata: '{}');
      await rooms.removeParticipant('class-7a', 'u-7');
      await rooms.sendData('class-7a', utf8.encode('hi'), topic: 'lk-chat');

      final [list, create, remove, send] = fake.recorded;
      expect(
        list.url.toString(),
        'https://lk.example.test/twirp/livekit.RoomService/ListRooms',
      );
      expect(list.data(), {
        'names': ['class-7a'],
      });
      expect(await grantOf(list), {'roomList': true});
      expect(create.data(), {
        'name': 'class-7a',
        'max_participants': 50,
        'metadata': '{}',
      });
      expect(await grantOf(create), {'roomCreate': true});
      expect(await grantOf(remove), {'roomAdmin': true, 'room': 'class-7a'});
      final sent = send.data();
      expect(sent['data'], base64.encode(utf8.encode('hi')));
      expect(sent['kind'], 0);
      expect(sent['topic'], 'lk-chat');
      expect(base64.decode(sent['nonce']! as String), hasLength(16));
    });

    test('a Twirp error is a LivekitException', () async {
      await expectLater(
        rooms.getParticipant('class-7a', 'nobody'),
        throwsA(
          isA<LivekitException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.message, 'message', contains('does not exist')),
        ),
      );
    });
  });

  test('configuration from .env, with older names', () {
    final config = LivekitConfig.fromEnv(
      Env.fromMap({
        'LIVEKIT_HOST': 'http://10.0.0.5:7880',
        'LIVEKIT_API_KEY': 'k',
        'LIVEKIT_SECRET_KEY': 's',
      }),
    );
    expect(
      (config.url, config.apiKey, config.apiSecret),
      ('http://10.0.0.5:7880', 'k', 's'),
    );
    expect(config.toMap()['api_secret'], '********');
    final current = LivekitConfig.fromEnv(
      Env.fromMap({
        'LIVEKIT_URL': 'wss://lk.example.test',
        'LIVEKIT_HOST': 'http://old',
        'LIVEKIT_API_SECRET': 'new',
        'LIVEKIT_SECRET_KEY': 'old',
      }),
    );
    expect((current.url, current.apiSecret), ('wss://lk.example.test', 'new'));
  });

  test('a key without a secret fails the boot; neither only warns', () async {
    Application build(Map<String, String> env) =>
        Application.configure(basePath: '.')
            .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
            .withLivekit()
            .create();
    final unset = build(const {});
    await unset.boot();
    addTearDown(unset.shutdown);
    expect(LivekitConfig.check(unset.env, unset.config).map((i) => i.level), [
      ConfigIssueLevel.warning,
    ]);
    final half = build(const {'LIVEKIT_API_KEY': 'k'});
    await expectLater(
      half.boot(),
      throwsA(
        predicate(
          (Object e) => '$e'.contains('LIVEKIT_API_SECRET is empty'),
          'names the missing secret',
        ),
      ),
    );
  });
}

void twirpRetryTests() {
  group('Twirp retries', () {
    late HttpClientFactory http;

    RoomServiceClient client({int retries = 2}) => RoomServiceClient(
      'http://lk.example.test',
      apiKey: _key,
      apiSecret: _secret,
      http: http,
      retries: retries,
      retryDelay: Duration.zero,
    );

    setUp(() => http = HttpClientFactory());

    test('a node that is unavailable or unreachable is tried again', () async {
      var drops = 0;
      final fake = http.fake({
        '*/CreateRoom': Http.sequence([
          Http.response({'msg': 'restarting'}, 503),
          Http.response({'msg': 'bad gateway'}, 502),
          Http.response({'sid': 'RM_1', 'name': 'a'}),
        ]),
        '*/ListRooms': (ClientRequest request) {
          if (drops++ == 0) {
            throw const ConnectionException('Could not reach: reset');
          }
          return Http.response({'rooms': <Object?>[]});
        },
      });
      expect((await client().createRoom('a')).name, 'a');
      expect(await client().listRooms(), isEmpty);
      expect(
        fake.recorded.where((r) => r.url.path.endsWith('CreateRoom')),
        hasLength(3),
      );
      expect(
        fake.recorded.where((r) => r.url.path.endsWith('ListRooms')),
        hasLength(2),
      );
    });

    test('other errors, timeouts and exhausted retries are final', () async {
      final fake = http.fake({
        '*/CreateRoom': Http.response({'code': 'not_found', 'msg': 'no'}, 404),
        '*/ListRooms': Http.sequence([
          Http.response({'msg': 'down'}, 503),
          Http.response({'msg': 'down'}, 503),
          Http.response({'msg': 'down'}, 503),
          Http.response({'msg': 'down'}, 503),
        ]),
        '*/DeleteRoom': (ClientRequest request) =>
            throw const ConnectionException('timed out', isTimeout: true),
      });
      await expectLater(
        client().createRoom('a'),
        throwsA(isA<LivekitException>().having((e) => e.status, 'status', 404)),
      );
      await expectLater(
        client().listRooms(),
        throwsA(isA<LivekitException>().having((e) => e.status, 'status', 503)),
      );
      await expectLater(
        client().deleteRoom('a'),
        throwsA(isA<ConnectionException>()),
      );
      expect(
        fake.recorded.where((r) => r.url.path.endsWith('CreateRoom')),
        hasLength(1),
        reason: '4xx is final',
      );
      expect(
        fake.recorded.where((r) => r.url.path.endsWith('ListRooms')),
        hasLength(3),
        reason: 'retries + 1',
      );
      expect(
        fake.recorded.where((r) => r.url.path.endsWith('DeleteRoom')),
        hasLength(1),
        reason: 'a timeout may have been processed',
      );
    });

    test('the backoff doubles with jitter and is capped', () {
      final rooms = RoomServiceClient(
        'http://lk',
        apiKey: _key,
        apiSecret: _secret,
        retryDelay: const Duration(milliseconds: 200),
      );
      for (var i = 0; i < 50; i++) {
        final first = rooms.backoff(0);
        expect(first.inMilliseconds, inInclusiveRange(100, 200));
        final second = rooms.backoff(1);
        expect(second.inMilliseconds, inInclusiveRange(200, 400));
        final far = rooms.backoff(20);
        expect(far.inMilliseconds, inInclusiveRange(2500, 5000));
      }
    });
  });
}
