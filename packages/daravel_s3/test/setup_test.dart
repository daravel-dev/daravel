import 'package:daravel/daravel.dart';
import 'package:daravel_s3/daravel_s3.dart';
import 'package:test/test.dart';

import 'support/fake_s3.dart';

void main() {
  late FakeS3 s3;

  setUp(() async => s3 = await FakeS3.start());
  tearDown(() => s3.close());

  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'APP_ENV': 'testing',
    'DB_DATABASE': ':memory:',
    'AWS_ACCESS_KEY_ID': s3.signer.accessKey,
    'AWS_SECRET_ACCESS_KEY': s3.signer.secretKey,
    'AWS_DEFAULT_REGION': s3.signer.region,
    'AWS_BUCKET': s3.bucket,
    'AWS_ENDPOINT': s3.endpoint,
    'AWS_USE_PATH_STYLE_ENDPOINT': 'true',
    ...extra,
  };

  Future<Application> boot(Map<String, String> env) async {
    final app = Application.configure(basePath: '.')
        .withEnv(env)
        .withS3()
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    return app;
  }

  test("withS3 reads Laravel's AWS_* names into the s3 disk", () async {
    final app = await boot(env());
    await app.run(() async {
      final disk = Storage.disk('s3');
      expect(disk, isA<S3Disk>());
      await disk.put('avatars/1.png', [137, 80, 78, 71]);
      expect(s3.objects.keys, ['avatars/1.png']);
      expect(
        App.make<ConfigRepository>().section<S3Config>().toMap()['secret'],
        '********',
      );
      // The local disks are still there.
      expect(Storage.disk('local'), isA<LocalDisk>());
    });
  });

  test('FILESYSTEM_DISK=s3 makes the Storage facade use the bucket', () async {
    final app = await boot(env({'FILESYSTEM_DISK': 's3'}));
    await app.run(() async {
      await Storage.put('hello.txt', 'from the facade');
      expect(await Storage.get('hello.txt'), 'from the facade');
      expect(s3.objects, contains('hello.txt'));
    });
  });

  test('an s3 default disk without credentials does not boot', () async {
    final app = Application.configure(basePath: '.')
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'FILESYSTEM_DISK': 's3',
          'AWS_VISIBILITY': 'world',
        })
        .withS3()
        .create();
    await expectLater(
      app.boot(),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('AWS_ACCESS_KEY_ID'),
            contains('AWS_BUCKET'),
            contains('AWS_VISIBILITY'),
          ),
        ),
      ),
    );
  });

  test('temporary URLs work on Storage.fake disks for tests', () async {
    final app = await boot(env());
    await app.run(() async {
      Storage.fake('s3');
      final expiration = DateTime.utc(2030);
      expect(
        Storage.disk('s3').temporaryUrl('a.pdf', expiration: expiration),
        '/storage/s3/a.pdf?expiration=${expiration.millisecondsSinceEpoch ~/ 1000}',
      );
      final upload = Storage.disk('s3').temporaryUploadUrl(
        'b.mp4',
        expiration: expiration,
        contentType: 'video/mp4',
      );
      expect(upload.headers, {'content-type': 'video/mp4'});
      expect(
        () => Storage.disk('local').temporaryUrl('a', expiration: expiration),
        throwsA(isA<StorageException>()),
      );
    });
  });
}
