import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('CACHE_PROCESS_MAX_ENTRIES bounds the process store', () {
    final defaults = CacheConfig.fromEnv(Env.fromMap(const {}));
    expect(defaults.processMaxEntries, 10000);
    expect(
      (defaults.toMap()['stores']! as Map)['process'],
      containsPair('max_entries', 10000),
    );
    final raised = CacheConfig.fromEnv(
      Env.fromMap(const {'CACHE_PROCESS_MAX_ENTRIES': '250000'}),
    );
    expect(raised.processMaxEntries, 250000);
    final coordinator = createStandardCoordinator(
      processCacheMaxEntries: raised.processMaxEntries,
    );
    final service =
        coordinator.service(ProcessCacheService.serviceName)!
            as ProcessCacheService;
    expect(service.store.maxEntries, 250000);
  });

  group('the array store (Laravel), daravel-feedback 021', () {
    test('CACHE_STORE=array reads as memory', () {
      final config = CacheConfig.fromEnv(
        Env.fromMap(const {'CACHE_STORE': 'array'}),
      );
      expect(config.defaultStore, 'memory');
    });

    test('Cache.store(array) is the memory store', () async {
      final manager = CacheManager(
        config: const CacheConfig(defaultStore: CacheManager.arrayStore),
        prefix: 'p_',
      )..extend('memory', MemoryStore.new);
      final array = manager.store(CacheManager.arrayStore);
      expect(array, same(manager.store('memory')));
      expect(manager.store(), same(array));
      await array.put('k', 'v');
      expect(await manager.store('memory').get<String>('k'), 'v');
    });

    test('a store registered as array is kept', () {
      final own = MemoryStore();
      final manager = CacheManager(config: const CacheConfig(), prefix: 'p_')
        ..extend('memory', MemoryStore.new)
        ..extend(CacheManager.arrayStore, () => own);
      expect(
        manager.store(CacheManager.arrayStore),
        isNot(same(manager.store('memory'))),
      );
    });
  });
}
