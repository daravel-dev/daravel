import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// On 1.x a URL-encoded form is read up to the whole body limit (50 MiB by
/// default; there is no smaller limit of its own for forms): its pairs are
/// counted on the bytes before it is decoded, so a large body over the
/// count is refused without being decoded or parsed.
void main() {
  test('a large form body under the body limit is refused on its count; '
      'one within the count is read', () async {
    final dir = Directory.systemTemp.createTempSync('input-vars-large-');
    final app = Application.configure(basePath: dir.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '',
          api: (router) => router.post(
            '/read',
            (request) async => {
              'pairs': ((await request.body())! as Map).length,
            },
          ),
        )
        .create();
    try {
      await app.boot();
      final value = 'v' * (8 << 10);
      Future<int> post(int pairs) async => (await app.handle(
        Request.fake(
          method: 'POST',
          path: '/read',
          body: [for (var i = 0; i < pairs; i++) 'k$i=$value'].join('&'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      )).status;
      // About 8 MiB, under the 50 MiB body limit.
      expect(await post(1001), 400);
      expect(await post(1000), 200);
    } finally {
      await app.shutdown();
      dir.deleteSync(recursive: true);
    }
  });
}
