import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late CacheRepository cache;

  setUp(() {
    Clock.fake(DateTime.utc(2026, 11, 1, 8));
    cache = CacheRepository(MemoryStore(clock: Clock.now), prefix: 'app:');
  });

  tearDown(Clock.restore);

  test('touch moves the expiry and keeps the value', () async {
    await cache.put('k', 'v', ttl: const Duration(minutes: 1));
    expect(await cache.touch('k', const Duration(hours: 1)), isTrue);
    Clock.travel(const Duration(minutes: 30));
    expect(await cache.get<String>('k'), 'v');
    Clock.travel(const Duration(minutes: 31));
    expect(await cache.get<String>('k'), isNull);
  });

  test('a missing key is false, and stays missing', () async {
    expect(await cache.touch('nope', const Duration(hours: 1)), isFalse);
    expect(await cache.has('nope'), isFalse);
  });

  test('a ttl of zero forgets, as Laravel', () async {
    await cache.put('k', 'v', ttl: const Duration(minutes: 1));
    expect(await cache.touch('k', Duration.zero), isTrue);
    expect(await cache.has('k'), isFalse);
  });
}
