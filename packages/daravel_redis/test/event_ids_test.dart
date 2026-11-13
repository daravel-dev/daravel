import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Stream ids from a client (`Last-Event-ID`) are read without `int.parse`:
/// nothing a client sends can throw, and a full 64-bit id from Redis is
/// compared right.
void main() {
  test('what a stream id is', () {
    for (final id in [
      '0-0',
      '1-2',
      '1700000000000-0',
      '007-01',
      '18446744073709551615-18446744073709551615',
      '0018446744073709551615-0',
    ]) {
      expect(RedisEventStream.isStreamId(id), isTrue, reason: id);
    }
    for (final id in [
      'abc',
      '1-',
      '-1',
      '1-2-3',
      '',
      '1',
      '18446744073709551616-0',
      '0-18446744073709551616',
      '1-a',
      '+1-2',
      '١-٢', // Arabic-Indic digits
    ]) {
      expect(RedisEventStream.isStreamId(id), isFalse, reason: id);
    }
  });

  test('which comes after which, past 64-bit ints', () {
    for (final (a, b, after) in [
      ('2-0', '1-9', true),
      ('1-10', '1-9', true),
      ('1-9', '1-10', false),
      ('1-1', '1-1', false),
      ('007-1', '7-0', true),
      ('18446744073709551615-0', '9223372036854775807-0', true),
      ('18446744073709551615-1', '18446744073709551615-0', true),
      ('12345678901234567890-0', '12345678901234567891-0', false),
    ]) {
      expect(RedisEventStream.streamIdAfter(a, b), after, reason: '$a > $b');
    }
    // Nothing a client sends throws.
    for (final bad in ['abc', '1-', '1-2-3', '18446744073709551616-0']) {
      expect(RedisEventStream.streamIdAfter(bad, '1-0'), isFalse);
      expect(RedisEventStream.streamIdAfter('1-0', bad), isFalse);
    }
  });
}
