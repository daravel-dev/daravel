import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_google/daravel_google.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

/// A throwaway RSA key, made for the run (no key file in the repository).
AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _keyPair() {
  final seed = Random.secure();
  final random = FortunaRandom()
    ..seed(
      KeyParameter(
        Uint8List.fromList([for (var i = 0; i < 32; i++) seed.nextInt(256)]),
      ),
    );
  return (RSAKeyGenerator()..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
          random,
        ),
      ))
      .generateKeyPair();
}

/// [key] as Google writes it in a key file: PEM PKCS#8 `PRIVATE KEY`.
String _pkcs8Pem(RSAPrivateKey key) {
  final d = key.privateExponent!;
  final p = key.p!;
  final q = key.q!;
  final rsa = ASN1Sequence(
    elements: [
      ASN1Integer(BigInt.zero),
      ASN1Integer(key.modulus),
      ASN1Integer(key.publicExponent),
      ASN1Integer(d),
      ASN1Integer(p),
      ASN1Integer(q),
      ASN1Integer(d % (p - BigInt.one)),
      ASN1Integer(d % (q - BigInt.one)),
      ASN1Integer(q.modInverse(p)),
    ],
  );
  final info = ASN1Sequence(
    elements: [
      ASN1Integer(BigInt.zero),
      ASN1Sequence(
        elements: [
          ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
          ASN1Null(),
        ],
      ),
      ASN1OctetString(octets: rsa.encode()),
    ],
  );
  final text = base64.encode(info.encode());
  final lines = [
    for (var i = 0; i < text.length; i += 64)
      text.substring(i, min(i + 64, text.length)),
  ];
  return '-----BEGIN PRIVATE KEY-----\n${lines.join('\n')}\n'
      '-----END PRIVATE KEY-----\n';
}

Map<String, Object?> _jwtPart(String part) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))))
        as Map<String, Object?>;

void main() {
  revokedTests();
  final now = DateTime.utc(2026, 10, 28, 7, 30);
  setUp(() => Clock.fake(now));
  tearDown(Clock.restore);

  group('GoogleToken', () {
    // The array google/apiclient stores (`users.google_cred` in Laravel).
    final stored = {
      'access_token': 'ya29.access',
      'expires_in': 3599,
      'created': now.millisecondsSinceEpoch ~/ 1000 - 600,
      'refresh_token': '1//refresh',
      'scope': 'openid https://www.googleapis.com/auth/calendar',
      'token_type': 'Bearer',
    };

    test('reads and writes google/apiclient\'s JSON as it is', () {
      final token = GoogleToken.parse(jsonEncode(stored));
      expect(token.accessToken, 'ya29.access');
      expect(token.refreshToken, '1//refresh');
      expect(token.hasScope(GoogleScopes.calendar), isTrue);
      expect(token.expiresAt, now.add(const Duration(seconds: 2999)));
      expect(token.toJson(), stored);
      expect(jsonDecode(token.encode()), stored);
    });

    test('is expired a minute before it expires', () {
      final token = GoogleToken.fromJson(stored);
      expect(token.expired(), isFalse);
      Clock.travel(const Duration(seconds: 2950));
      expect(token.expired(), isTrue);
    });

    test('a refresh keeps the refresh token Google did not resend', () {
      final old = GoogleToken.fromJson(stored);
      final fresh = GoogleToken.fromResponse({
        'access_token': 'ya29.new',
        'expires_in': 3599,
        'token_type': 'Bearer',
      });
      final renewed = old.renewedBy(fresh);
      expect(renewed.accessToken, 'ya29.new');
      expect(renewed.refreshToken, '1//refresh');
      expect(renewed.created, now);
      expect(renewed.scopes, old.scopes);
    });
  });

  group('GoogleOAuth', () {
    late HttpClientFactory http;
    late HttpFake fake;
    late GoogleOAuth oauth;

    setUp(() {
      http = HttpClientFactory();
      fake = http.fake({
        GoogleOAuth.tokenEndpoint: (ClientRequest request) =>
            request.data()['refresh_token'] == 'revoked'
            ? Http.response({
                'error': 'invalid_grant',
                'error_description': 'Token has been expired or revoked.',
              }, 400)
            : Http.response({
                'access_token': 'ya29.new',
                'expires_in': 3599,
                'scope': GoogleScopes.calendar,
                'token_type': 'Bearer',
              }),
        GoogleOAuth.revocationEndpoint: Http.response(<String, Object?>{}),
      });
      oauth = GoogleOAuth(
        clientId: 'client.apps.googleusercontent.com',
        clientSecret: 'shh',
        redirectUri: 'https://app.test/google/callback',
        http: http,
      );
    });

    test('the consent URL asks for offline access', () {
      final url = oauth.authorizationUrl(
        scopes: [GoogleScopes.openid, GoogleScopes.calendar],
        state: 'csrf',
      );
      expect(url.origin, 'https://accounts.google.com');
      expect(url.queryParameters, {
        'client_id': 'client.apps.googleusercontent.com',
        'redirect_uri': 'https://app.test/google/callback',
        'response_type': 'code',
        'scope': 'openid https://www.googleapis.com/auth/calendar',
        'state': 'csrf',
        'access_type': 'offline',
        'prompt': 'consent',
        'include_granted_scopes': 'true',
      });
    });

    test('exchanges a code and refreshes, as forms', () async {
      final token = await oauth.exchangeCode('4/code');
      expect(token.accessToken, 'ya29.new');
      expect(token.created, now);
      final exchange = fake.recorded.single;
      expect(exchange.header('content-type'), contains('form-urlencoded'));
      expect(exchange.data(), {
        'grant_type': 'authorization_code',
        'code': '4/code',
        'redirect_uri': 'https://app.test/google/callback',
        'client_id': 'client.apps.googleusercontent.com',
        'client_secret': 'shh',
      });

      final stored = GoogleToken(
        accessToken: 'ya29.old',
        created: now.subtract(const Duration(hours: 2)),
        expiresIn: const Duration(hours: 1),
        refreshToken: '1//refresh',
      );
      final refreshed = await oauth.refresh(stored);
      expect(refreshed.accessToken, 'ya29.new');
      expect(refreshed.refreshToken, '1//refresh');
      expect(fake.recorded.last.data()['grant_type'], 'refresh_token');
    });

    test('a revoked refresh token is invalid_grant', () async {
      final revoked = GoogleToken(
        accessToken: 'ya29.old',
        created: now,
        expiresIn: Duration.zero,
        refreshToken: 'revoked',
      );
      await expectLater(
        oauth.refresh(revoked),
        throwsA(
          isA<GoogleException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.reason, 'reason', 'invalid_grant'),
        ),
      );
    });

    test('revokes the refresh token', () async {
      await oauth.revoke(
        GoogleToken(
          accessToken: 'ya29.a',
          created: now,
          expiresIn: Duration.zero,
          refreshToken: '1//r',
        ),
      );
      expect(fake.recorded.single.data(), {'token': '1//r'});
    });
  });

  group('GoogleServiceAccount', () {
    final keys = _keyPair();
    late HttpClientFactory http;
    late HttpFake fake;
    late GoogleServiceAccount account;

    setUp(() {
      http = HttpClientFactory();
      fake = http.fake({
        GoogleServiceAccount.defaultTokenUri: Http.response({
          'access_token': 'ya29.service',
          'expires_in': 3599,
          'token_type': 'Bearer',
        }),
      });
      account = GoogleServiceAccount.fromJson({
        'type': 'service_account',
        'project_id': 'demo',
        'private_key_id': 'kid-1',
        'private_key': _pkcs8Pem(keys.privateKey),
        'client_email': 'calendar@demo.iam.gserviceaccount.com',
        'token_uri': GoogleServiceAccount.defaultTokenUri,
      }, http: http);
    });

    test('signs an RS256 assertion (RFC 7523) the public key verifies', () {
      final jwt = account.assertion(
        scopes: [GoogleScopes.calendar],
        subject: 'guru@sekolah.sch.id',
      );
      final [header, claims, signature] = jwt.split('.');
      expect(_jwtPart(header), {'alg': 'RS256', 'typ': 'JWT', 'kid': 'kid-1'});
      final iat = now.millisecondsSinceEpoch ~/ 1000;
      expect(_jwtPart(claims), {
        'iss': 'calendar@demo.iam.gserviceaccount.com',
        'scope': GoogleScopes.calendar,
        'aud': 'https://oauth2.googleapis.com/token',
        'iat': iat,
        'exp': iat + 3600,
        'sub': 'guru@sekolah.sch.id',
      });
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(keys.publicKey));
      expect(
        verifier.verifySignature(
          utf8.encode('$header.$claims'),
          RSASignature(base64Url.decode(base64Url.normalize(signature))),
        ),
        isTrue,
      );
    });

    test('concurrent calls share one token fetch', () async {
      final credentials = ServiceAccountCredentials(
        account,
        scopes: const [GoogleScopes.calendar],
      );
      final tokens = await Future.wait([
        credentials.accessToken(),
        credentials.accessToken(),
        credentials.accessToken(),
      ]);
      expect(tokens, ['ya29.service', 'ya29.service', 'ya29.service']);
      expect(fake.recorded, hasLength(1), reason: 'one assertion, one fetch');
      expect(await credentials.accessToken(), 'ya29.service');
      expect(fake.recorded, hasLength(1), reason: 'still valid');
    });

    test('gets a token with the jwt-bearer grant', () async {
      final token = await account.token(scopes: [GoogleScopes.calendar]);
      expect(token.accessToken, 'ya29.service');
      final sent = fake.recorded.single.data();
      expect(sent['grant_type'], 'urn:ietf:params:oauth:grant-type:jwt-bearer');
      expect((sent['assertion']! as String).split('.'), hasLength(3));
    });

    test('reads a PKCS#1 key and a key with escaped newlines', () {
      final pem = _pkcs8Pem(keys.privateKey);
      expect(
        GoogleServiceAccount.parsePrivateKey(pem.replaceAll('\n', r'\n'))
            .modulus,
        keys.privateKey.modulus,
      );
      expect(
        () => GoogleServiceAccount.fromJson({'type': 'authorized_user'}),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('credentials', () {
    test('a user token refreshes once for calls at the same time', () async {
      final http = HttpClientFactory();
      final fake = http.fake({
        GoogleOAuth.tokenEndpoint: Http.response({
          'access_token': 'ya29.new',
          'expires_in': 3599,
        }),
      });
      final stored = <GoogleToken>[];
      final credentials = UserCredentials(
        GoogleToken(
          accessToken: 'ya29.old',
          created: now.subtract(const Duration(hours: 2)),
          expiresIn: const Duration(hours: 1),
          refreshToken: '1//refresh',
        ),
        oauth: GoogleOAuth(clientId: 'id', clientSecret: 's', http: http),
        onRefresh: stored.add,
      );
      final tokens = await Future.wait([
        credentials.accessToken(),
        credentials.accessToken(),
        credentials.accessToken(),
      ]);
      expect(tokens, ['ya29.new', 'ya29.new', 'ya29.new']);
      expect(fake.recorded, hasLength(1));
      expect(stored.single.refreshToken, '1//refresh');
      expect(await credentials.accessToken(), 'ya29.new');
      expect(fake.recorded, hasLength(1), reason: 'still valid');
    });

    test(
      'a store that fails keeps the old token, so the next call retries',
      () async {
        final http = HttpClientFactory();
        final fake = http.fake({
          GoogleOAuth.tokenEndpoint: Http.response({
            'access_token': 'ya29.new',
            'expires_in': 3599,
          }),
        });
        final old = GoogleToken(
          accessToken: 'ya29.old',
          created: now.subtract(const Duration(hours: 2)),
          expiresIn: const Duration(hours: 1),
          refreshToken: '1//refresh',
        );
        var storeFails = true;
        final stored = <GoogleToken>[];
        final credentials = UserCredentials(
          old,
          oauth: GoogleOAuth(clientId: 'id', clientSecret: 's', http: http),
          onRefresh: (token) {
            if (storeFails) {
              throw StateError('database down');
            }
            stored.add(token);
          },
        );
        await expectLater(credentials.accessToken(), throwsStateError);
        // Not in memory either: a token the store never saw would be served
        // by this isolate only, and silently.
        expect(credentials.token, same(old));
        storeFails = false;
        expect(await credentials.accessToken(), 'ya29.new');
        expect(fake.recorded, hasLength(2), reason: 'refreshed again');
        expect(stored.single.accessToken, 'ya29.new');
      },
    );

    test('the service account token is fetched once per isolate', () async {
      final keys = _keyPair();
      final file = File('${Directory.systemTemp.path}/daravel_google_sa.json')
        ..writeAsStringSync(
          jsonEncode({
            'type': 'service_account',
            'project_id': 'demo',
            'private_key_id': 'kid-1',
            'private_key': _pkcs8Pem(keys.privateKey),
            'client_email': 'calendar@demo.iam.gserviceaccount.com',
            'token_uri': GoogleServiceAccount.defaultTokenUri,
          }),
        );
      addTearDown(file.delete);
      final app = Application.configure(basePath: '.')
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'GOOGLE_APPLICATION_CREDENTIALS': file.path,
          })
          .withGoogle()
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      await app.run(() async {
        final fake = App.make<HttpClientFactory>().fake({
          GoogleServiceAccount.defaultTokenUri: Http.response({
            'access_token': 'ya29.service',
            'expires_in': 3599,
            'token_type': 'Bearer',
          }),
          '*': Http.response({'id': 'evt1'}),
        });
        // Each call used to build new credentials: an RSA signature and a
        // token request per API call.
        await Google.serviceCalendar().get('evt1');
        await Google.serviceCalendar().get('evt1');
        await Google.serviceCalendar(subject: 'guru@sekolah.sch.id').get('e');
        final tokenCalls = fake.recorded.where(
          (r) => r.url.toString() == GoogleServiceAccount.defaultTokenUri,
        );
        expect(tokenCalls, hasLength(2), reason: 'one per subject');
        expect(App.make<ServiceAccountCredentialsCache>().size, 2);
        expect(
          identical(
            Google.serviceCredentials(scopes: const [GoogleScopes.calendar]),
            Google.serviceCredentials(scopes: const [GoogleScopes.calendar]),
          ),
          isTrue,
        );
      });
    });
  });

  group('GoogleCalendar', () {
    late HttpClientFactory http;
    late HttpFake fake;
    late GoogleCalendar calendar;

    final created = {
      'id': 'evt1',
      'status': 'confirmed',
      'htmlLink': 'https://www.google.com/calendar/event?eid=evt1',
      'summary': 'Matematika XI',
      'start': {
        'dateTime': '2026-10-28T07:30:00+08:00',
        'timeZone': 'Asia/Makassar',
      },
      'end': {
        'dateTime': '2026-10-28T09:00:00+08:00',
        'timeZone': 'Asia/Makassar',
      },
      'attendees': [
        {'email': 'siswa@sekolah.sch.id', 'responseStatus': 'needsAction'},
      ],
      'hangoutLink': 'https://meet.google.com/abc-defg-hij',
      'conferenceData': {
        'createRequest': {
          'status': {'statusCode': 'success'},
        },
        'entryPoints': [
          {'entryPointType': 'phone', 'uri': 'tel:+62-21-0000'},
          {
            'entryPointType': 'video',
            'uri': 'https://meet.google.com/abc-defg-hij',
          },
        ],
      },
    };

    setUp(() {
      http = HttpClientFactory();
      fake = http.fake({
        '*/events/gone*': Http.response({
          'error': {
            'code': 410,
            'message': 'Resource has been deleted',
            'errors': [
              {'reason': 'deleted'},
            ],
          },
        }, 410),
        '*/events/missing*': Http.response({
          'error': {
            'code': 404,
            'message': 'Not Found',
            'errors': [
              {'reason': 'notFound'},
            ],
          },
        }, 404),
        '*/events?singleEvents=true*pageToken=p2*': Http.response({
          'items': [
            {'id': 'e3'},
          ],
        }),
        '*/events?singleEvents=true*': Http.response({
          'items': [
            {'id': 'e1'},
            {'id': 'e2'},
          ],
          'nextPageToken': 'p2',
        }),
        '*': Http.response(created),
      });
      calendar = GoogleCalendar(
        const GoogleCredentials.token('ya29.user'),
        calendarId: 'kelas#xi@group.calendar.google.com',
        timeZone: 'Asia/Makassar',
        http: http,
      );
    });

    test('creates an event with guests and a Meet link', () async {
      final event = await calendar.create(
        CalendarEvent(
          summary: 'Matematika XI',
          start: EventTime(DateTime(2026, 10, 28, 7, 30)),
          end: EventTime(DateTime(2026, 10, 28, 9)),
          attendees: const [
            EventAttendee('siswa@sekolah.sch.id', displayName: 'Siswa'),
          ],
          meet: true,
        ),
      );
      expect(event.id, 'evt1');
      expect(event.meetUrl, 'https://meet.google.com/abc-defg-hij');
      expect(event.conferenceStatus, 'success');
      expect(event.attendees!.single.responseStatus, 'needsAction');
      expect(event.start!.timeZone, 'Asia/Makassar');

      final request = fake.recorded.single;
      expect(request.method, 'POST');
      expect(request.header('authorization'), 'Bearer ya29.user');
      expect(
        request.url.path,
        '/calendar/v3/calendars/kelas%23xi%40group.calendar.google.com/events',
      );
      expect(request.url.queryParameters, {
        'conferenceDataVersion': '1',
        'sendUpdates': 'all',
      });
      final body = request.data();
      expect(body['start'], {
        'dateTime': '2026-10-28T07:30:00',
        'timeZone': 'Asia/Makassar',
      });
      expect(body['attendees'], [
        {'email': 'siswa@sekolah.sch.id', 'displayName': 'Siswa'},
      ]);
      final conference = (body['conferenceData']! as Map)['createRequest']!;
      expect((conference as Map)['conferenceSolutionKey'], {
        'type': 'hangoutsMeet',
      });
      expect(conference['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('a UTC time is an instant; an all-day event has a date', () {
      final body = CalendarEvent(
        start: EventTime(DateTime.utc(2026, 10, 28, 1)),
        end: EventTime.date(DateTime(2026, 10, 29)),
      ).toJson('Asia/Makassar');
      expect(body, {
        'start': {'dateTime': '2026-10-28T01:00:00.000Z'},
        'end': {'date': '2026-10-29'},
      });
    });

    test('patch sends only what changes', () async {
      await calendar.patch(
        'evt1',
        CalendarEvent(summary: 'Matematika XI (diundur)'),
        sendUpdates: SendUpdates.none,
      );
      final request = fake.recorded.single;
      expect(request.method, 'PATCH');
      expect(request.data(), {'summary': 'Matematika XI (diundur)'});
      expect(request.url.queryParameters['sendUpdates'], 'none');
    });

    test('lists every page in order of start', () async {
      final events = await calendar.list(
        from: DateTime.utc(2026, 10, 28),
        to: DateTime.utc(2026, 10, 29),
      );
      expect([for (final e in events) e.id], ['e1', 'e2', 'e3']);
      final first = fake.recorded.first.url.queryParameters;
      expect(first['singleEvents'], 'true');
      expect(first['orderBy'], 'startTime');
      expect(first['timeMin'], '2026-10-28T00:00:00.000Z');
    });

    test('a deleted event deletes fine; a missing one throws', () async {
      await calendar.delete('gone');
      await expectLater(
        calendar.get('missing'),
        throwsA(
          isA<GoogleException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.reason, 'reason', 'notFound'),
        ),
      );
    });
  });

  test('withGoogle reads Laravel\'s and Google\'s names', () async {
    final app = Application.configure(basePath: '.')
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'APP_TIMEZONE': 'Asia/Makassar',
          'GOOGLE_CLIENT_ID': 'id.apps.googleusercontent.com',
          'GOOGLE_CLIENT_SECRET': 'shh',
          'GOOGLE_REDIRECT_URI': 'https://app.test/google/callback',
          'GOOGLE_CALENDAR_ID': 'kelas@group.calendar.google.com',
        })
        .withGoogle()
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      final fake = App.make<HttpClientFactory>().fake({
        '*': Http.response({'id': 'evt1'}),
      });
      expect(Google.config.toMap()['client_secret'], '********');
      expect(Google.oauth.redirectUri, 'https://app.test/google/callback');
      final calendar = Google.calendar(const GoogleCredentials.token('t'));
      expect(calendar.calendarId, 'kelas@group.calendar.google.com');
      expect(calendar.timeZone, 'Asia/Makassar');
      await calendar.get('evt1');
      expect(fake.recorded, hasLength(1), reason: "the application's client");
      expect(
        () => Google.serviceAccount,
        throwsA(isA<ConfigException>()),
        reason: 'no GOOGLE_APPLICATION_CREDENTIALS',
      );
    });
  });
}

void revokedTests() {
  test('a revoked refresh token is not retried on every call', () async {
    final http = HttpClientFactory();
    final fake = http.fake({
      GoogleOAuth.tokenEndpoint: Http.response({
        'error': 'invalid_grant',
        'error_description': 'Token has been expired or revoked.',
      }, 400),
    });
    final credentials = UserCredentials(
      GoogleToken(
        accessToken: 'ya29.old',
        created: DateTime.utc(2026, 10, 28).subtract(const Duration(hours: 2)),
        expiresIn: const Duration(hours: 1),
        refreshToken: '1//revoked',
      ),
      oauth: GoogleOAuth(clientId: 'id', clientSecret: 's', http: http),
    );
    for (var i = 0; i < 3; i++) {
      await expectLater(
        credentials.accessToken(),
        throwsA(
          isA<GoogleException>().having(
            (e) => e.reason,
            'reason',
            'invalid_grant',
          ),
        ),
      );
    }
    expect(fake.recorded, hasLength(1), reason: 'asked Google once');
    expect(credentials.revoked, isNotNull);
    // The client remembers it too, so credentials built afresh for each
    // request (Google.calendarFor) do not ask again either.
    final oauth = credentials.oauth;
    expect(oauth.isRevoked(credentials.token), isTrue);
    await expectLater(
      UserCredentials(credentials.token, oauth: oauth).accessToken(),
      throwsA(
        isA<GoogleException>().having(
          (e) => e.reason,
          'reason',
          'invalid_grant',
        ),
      ),
    );
    expect(fake.recorded, hasLength(1), reason: 'still once');
    // After the user consented again.
    credentials.replace(
      GoogleToken(
        accessToken: 'ya29.new',
        created: Clock.now().toUtc(),
        expiresIn: const Duration(hours: 1),
        refreshToken: '1//fresh',
      ),
    );
    expect(credentials.revoked, isNull);
    expect(await credentials.accessToken(), 'ya29.new');
  });
}
