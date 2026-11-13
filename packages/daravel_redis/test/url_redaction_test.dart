import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// DB-1 (Reviewer RSEQ 49): a malformed REDIS_URL failed with
/// `Uri.parse`'s own FormatException, which quotes the whole URL and its
/// password.
void main() {
  const secret = 'S3cr3tPW';

  test('a malformed REDIS_URL is reported without its password', () {
    for (final url in [
      'redis://app:$secret@[::1/0', // malformed host
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
