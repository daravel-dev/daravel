import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Coordinator coordinator;
  setUp(() => coordinator = createStandardCoordinator());
  tearDown(() => coordinator.close());

  final stores = <String, CacheStore Function()>{
    'memory': MemoryStore.new,
    'process': () => ProcessStore(LocalCoordinatorChannel(coordinator)),
  };

  for (final MapEntry(key: name, value: build) in stores.entries) {
    group('tags on the $name store', () {
      late CacheRepository cache;
      setUp(() => cache = CacheRepository(build(), prefix: 'app_'));

      test('entries live under their tags, in order', () async {
        await cache.tags(['people', 'artists']).put('John', 'x');
        expect(
          await cache.tags(['people', 'artists']).get<String>('John'),
          'x',
        );
        expect(
          await cache.tags(['artists', 'people']).get<String>('John'),
          isNull,
        );
        expect(await cache.get<String>('John'), isNull);
        final key = await (cache.tags(['people']).store as TaggedCacheStore)
            .itemKey('John');
        expect(key, matches(RegExp(r'^app_[0-9a-f]{40}:John$')));
      });

      test('a flush forgets what its tags hold, and nothing else', () async {
        await cache.put('plain', 1);
        await cache.tags(['a']).put('one', 1);
        await cache.tags(['a', 'b']).put('two', 2);
        await cache.tags(['b']).put('three', 3);
        await cache.tags(['a']).flush();
        expect(await cache.tags(['a']).get<int>('one'), isNull);
        expect(await cache.tags(['a', 'b']).get<int>('two'), isNull);
        expect(await cache.tags(['b']).get<int>('three'), 3);
        expect(await cache.get<int>('plain'), 1);
      });

      test('remember, increment, many and locks', () async {
        final tagged = cache.tags(['counts']);
        expect(await tagged.remember('n', null, () => 5), 5);
        expect(await tagged.remember('n', null, () => 9), 5);
        expect(await tagged.increment('hits', 2), 2);
        expect(await tagged.many(['n', 'hits', 'none']), {
          'n': 5,
          'hits': 2,
          'none': null,
        });
        // Locks are not tagged: the same lock as without tags.
        final lock = tagged.lock('job');
        expect(await lock.acquire(), isTrue);
        expect(await cache.lock('job').acquire(), isFalse);
        await lock.release();
      });
    });
  }

  test('the file store cannot tag, as in Laravel', () {
    final dir = Directory.systemTemp.createTempSync('tags_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = CacheRepository(FileStore(dir.path));
    expect(
      () => cache.tags(['a']),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          'This cache store does not support tagging.',
        ),
      ),
    );
  });
}
