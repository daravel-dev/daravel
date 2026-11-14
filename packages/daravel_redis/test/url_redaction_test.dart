import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// DB-1 (Reviewer RSEQ 49): a malformed REDIS_URL failed with
/// `Uri.parse`'s own FormatException, which quotes the whole URL and its
/// password.
void main() {
  passwordWithColonTests();
  const secret = 'S3cr3tPW';

  test('a malformed REDIS_URL is reported without its password', () {
    for (final url in [
      'redis://app:$secret@[::1/0', // malformed host
      'redis://h:6379/notanumber?token=$secret', // token in the query
      'redis://:$secret@[::1/0', // no user
      'redis://$secret@[::1/0', // a lone user info is the password
      'rediss://app:$secret@h/%zz', // malformed escape
      'redis://app:$secret@h/notanumber',
      'redis+cluster://app:$secret@h:x',
    ]) {
      Object? error;
      try {
        RedisConnectionConfig.fromUrl(url);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<ConfigException>(), reason: url);
      expect('$error', isNot(contains(secret)), reason: url);
    }
  });

  test('REDIS_URL through fromEnv, too', () {
    expect(
      () => RedisConnectionConfig.fromEnv(
        Env.fromMap({'REDIS_URL': 'redis://:$secret@[::1/0'}),
      ),
      throwsA(
        isA<ConfigException>().having(
          (e) => '$e',
          'message',
          isNot(contains(secret)),
        ),
      ),
    );
  });

  test('valid URLs still parse', () {
    expect(RedisConnectionConfig.fromUrl('redis://:pw@h').password, 'pw');
    expect(RedisConnectionConfig.fromUrl('redis://pw@h').password, 'pw');
    expect(RedisConnectionConfig.fromUrl('redis://u:pw@h/3').database, 3);
  });
}

void passwordWithColonTests() {
  // RSEQ 53 #7: the two-element pattern made such a password null.
  test('a password holding `:` reaches the config whole', () {
    expect(
      RedisConnectionConfig.fromUrl('redis://app:pa:ss@h').password,
      'pa:ss',
    );
    expect(
      RedisConnectionConfig.fromUrl(
        'redis+sentinel://app:pa:ss@h:26379/mymaster',
      ).password,
      'pa:ss',
    );
    expect(RedisConnectionConfig.fromUrl('redis://:a:b@h').password, 'a:b');
  });

  // The server's own check: an ACL user whose password holds `:`, so the
  // password has to reach AUTH whole. A user rather than requirepass, so
  // the server stays open for the other tests. Needs DARAVEL_TEST_REDIS.
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  test('a password holding `:` authenticates on the server', () async {
    final server = Uri.parse(url!);
    final name = 'hc1_${Random().nextInt(1 << 30)}';
    final admin = RedisClient(RedisConnectionConfig.fromUrl(url));
    addTearDown(() async {
      await admin.command(['ACL', 'DELUSER', name]);
      await admin.close();
    });
    await admin.command([
      'ACL', 'SETUSER', name, 'on', '>pa:ss:w', '~*', '&*', '+@all', //
    ]);
    final user = RedisClient(
      RedisConnectionConfig.fromUrl(
        '${server.scheme}://$name:pa:ss:w@${server.host}:'
        '${server.hasPort ? server.port : 6379}${server.path}',
      ),
    );
    addTearDown(user.close);
    expect(await user.command(['ACL', 'WHOAMI']), name);
  }, skip: url == null || url.isEmpty ? 'DARAVEL_TEST_REDIS not set' : false);
}
