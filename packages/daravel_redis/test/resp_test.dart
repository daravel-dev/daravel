import 'dart:convert';

import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

List<Object?> decodeAll(String stream, {int chunk = 0}) {
  final values = <Object?>[];
  final decoder = RespDecoder(values.add);
  final bytes = utf8.encode(stream);
  if (chunk == 0) {
    decoder.add(bytes);
  } else {
    for (var i = 0; i < bytes.length; i += chunk) {
      decoder.add(
        bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk),
      );
    }
  }
  return values;
}

void main() {
  test('a command is an array of bulk strings', () {
    expect(
      utf8.decode(encodeCommand(['SET', 'clé', 42])),
      '*3\r\n\$3\r\nSET\r\n\$4\r\nclé\r\n\$2\r\n42\r\n',
    );
  });

  const resp2 =
      '+OK\r\n-ERR wrong\r\n:42\r\n\$5\r\nhallo\r\n\$-1\r\n'
      '*2\r\n\$1\r\na\r\n:1\r\n*-1\r\n*0\r\n\$0\r\n\r\n';

  test('RESP2 values', () {
    final values = decodeAll(resp2);
    expect(values[0], 'OK');
    expect((values[1]! as RespError).message, 'ERR wrong');
    expect(values.sublist(2), [
      42,
      'hallo',
      null,
      ['a', 1],
      null,
      <Object?>[],
      '',
    ]);
  });

  test('values split at every byte decode the same', () {
    final whole = decodeAll(resp2);
    final split = decodeAll(resp2, chunk: 1);
    expect(split.length, whole.length);
    expect(split.sublist(2), whole.sublist(2));
  });

  test('a bulk string keeps CRLF and multibyte text inside it', () {
    const text = 'baris\r\nkedua ✓';
    final bytes = utf8.encode(text).length;
    expect(decodeAll('\$$bytes\r\n$text\r\n', chunk: 3), [text]);
  });

  test('RESP3 values', () {
    final values = decodeAll(
      '_\r\n,3.5\r\n#t\r\n#f\r\n(12345678901234567890\r\n'
      '=7\r\ntxt:abc\r\n%1\r\n+k\r\n:1\r\n~2\r\n:1\r\n:2\r\n'
      '>2\r\n+message\r\n+x\r\n|1\r\n+ttl\r\n:3\r\n+after\r\n'
      '!5\r\nERR x\r\n',
    );
    expect(values[0], isNull);
    expect(values[1], 3.5);
    expect(values.sublist(2, 4), [true, false]);
    expect(values[4], BigInt.parse('12345678901234567890'));
    expect(values[5], 'abc');
    expect(values[6], {'k': 1});
    expect(values[7], [1, 2]);
    expect((values[8]! as RespPush).items, ['message', 'x']);
    expect(values[9], 'after', reason: 'attributes are skipped');
    expect((values[10]! as RespError).message, 'ERR x');
  });

  test('error codes', () {
    expect(
      const RedisCommandException('NOSCRIPT No matching script').code,
      'NOSCRIPT',
    );
  });

  group('refuses what would exhaust memory', () {
    test('a bulk string over the limit', () {
      final decoder = RespDecoder((_) {}, maxBulkBytes: 10);
      expect(() => decoder.add(utf8.encode('\$11\r\n')), throwsFormatException);
    });

    test('an aggregate over the limit', () {
      final decoder = RespDecoder((_) {}, maxElements: 3);
      expect(() => decoder.add(utf8.encode('*4\r\n')), throwsFormatException);
    });

    test('nesting deeper than the limit', () {
      final decoder = RespDecoder((_) {}, maxDepth: 3);
      expect(
        () => decoder.add(utf8.encode('${'*1\r\n' * 5}:1\r\n')),
        throwsFormatException,
      );
    });

    test('an unknown type', () {
      final decoder = RespDecoder((_) {});
      expect(() => decoder.add(utf8.encode('?x\r\n')), throwsFormatException);
    });
  });

  group('configuration', () {
    test('REDIS_URL with user, password, database and TLS', () {
      final config = RedisConnectionConfig.fromUrl(
        'rediss://app:s%40cret@cache.example.com:6380/2',
      );
      expect(config.host, 'cache.example.com');
      expect(config.port, 6380);
      expect(config.username, 'app');
      expect(config.password, 's@cret');
      expect(config.database, 2);
      expect(config.tls, isTrue);
      expect(config.toString(), isNot(contains('cret')));
      expect(config.redacted, 'rediss://app:********@cache.example.com:6380/2');
    });

    test('a password without a user', () {
      final config = RedisConnectionConfig.fromUrl('redis://:pw@127.0.0.1');
      expect(config.username, isNull);
      expect(config.password, 'pw');
      expect(config.port, 6379);
    });

    test('private hosts need no TLS', () {
      for (final host in ['127.0.0.1', 'localhost', 'redis', '10.0.0.5']) {
        expect(RedisConnectionConfig(host: host).isPrivateHost, isTrue);
      }
      expect(
        const RedisConnectionConfig(host: 'cache.example.com').isPrivateHost,
        isFalse,
      );
    });
  });
}
