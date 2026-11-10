import 'package:daravel/daravel.dart';
import 'package:daravel_pulse/daravel_pulse.dart';
import 'package:test/test.dart';

void main() {
  test('the Queues card links to daravel_horizon by its route name', () {
    final router = Router();
    expect(Pulse.horizonPath(router), isNull);
    router
        .get('/ops/horizon', (Request request) => Response.text(''))
        .name('horizon.index');
    expect(Pulse.horizonPath(router), '/ops/horizon');
  });
}
