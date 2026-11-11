import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

import 'support/store_contract.dart';

/// The `process` store against the [HorizonStore] contract; the `database`
/// and `redis` stores run the same.
void main() {
  late Coordinator coordinator;

  horizonStoreContract('process', () async {
    var now = DateTime.utc(2026);
    coordinator = createStandardCoordinator()
      ..register(HorizonService(clock: () => now));
    final channel = LocalCoordinatorChannel(coordinator);
    return (
      store: ProcessHorizonStore(() => channel) as HorizonStore,
      setNow: (DateTime at) => now = at,
    );
  }, tearDownStore: () async => coordinator.close());

  test('record never throws, even without a Horizon service', () async {
    final bare = createStandardCoordinator();
    addTearDown(bare.close);
    final store = ProcessHorizonStore(() => LocalCoordinatorChannel(bare));
    await store.record(
      const RecordedJob(
        uuid: 'a',
        name: 'X',
        queue: 'q',
        status: 'completed',
        at: 0,
      ),
    );
  });
}
