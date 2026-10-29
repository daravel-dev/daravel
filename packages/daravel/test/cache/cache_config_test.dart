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
}
