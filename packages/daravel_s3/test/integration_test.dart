@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel_s3/daravel_s3.dart';
import 'package:test/test.dart';

import 'support/disk_contract.dart';

/// The disk contract against a real S3-compatible server:
/// `DARAVEL_TEST_S3=http://127.0.0.1:9000` (path style, keys
/// `minioadmin` / `minioadmin`, bucket `daravel-test`, all overridable
/// with `DARAVEL_TEST_S3_KEY`, `_SECRET`, `_BUCKET` and `_REGION`). CI
/// runs RustFS (MinIO's images are no longer published): `docker run -p
/// 9000:9000 -e RUSTFS_ACCESS_KEY=minioadmin -e
/// RUSTFS_SECRET_KEY=minioadmin rustfs/rustfs:1.0.4 /data`.
void main() {
  final environment = Platform.environment;
  final endpoint = environment['DARAVEL_TEST_S3'];
  if (endpoint == null || endpoint.isEmpty) {
    test('S3 server (skipped: DARAVEL_TEST_S3 not set)', () {}, skip: true);
    return;
  }
  final config = S3Config(
    accessKey: environment['DARAVEL_TEST_S3_KEY'] ?? 'minioadmin',
    secretKey: environment['DARAVEL_TEST_S3_SECRET'] ?? 'minioadmin',
    region: environment['DARAVEL_TEST_S3_REGION'] ?? 'us-east-1',
    bucket: environment['DARAVEL_TEST_S3_BUCKET'] ?? 'daravel-test',
    endpoint: endpoint,
    usePathStyleEndpoint: true,
  );
  final admin = S3Disk.fromConfig('s3', config);
  tearDownAll(admin.client.close);

  setUpAll(() async {
    // Creates the bucket; 409 when it exists already.
    await admin.client.send('PUT', '', accept: const {200, 409});
  });

  // Every test gets its own root, removed afterwards.
  late S3Disk disk;
  tearDown(() async {
    final keys = (await disk.client.listObjects(disk.key(''))).keys;
    if (keys.isNotEmpty) {
      await disk.client.deleteObjects(keys);
    }
    disk.client.close();
  });

  group('contract', () {
    diskContract(() async {
      disk = S3Disk.fromConfig(
        's3',
        S3Config(
          accessKey: config.accessKey,
          secretKey: config.secretKey,
          region: config.region,
          bucket: config.bucket,
          endpoint: config.endpoint,
          usePathStyleEndpoint: true,
          root: 'run-${Random().nextInt(1 << 32)}',
        ),
      );
      return disk;
    });
  });

  test('multipart upload of 11 MiB with 5 MiB parts', () async {
    disk = S3Disk(
      's3',
      S3Disk.fromConfig('s3', config).client,
      root: 'run-${Random().nextInt(1 << 32)}',
      partSize: 5 * 1024 * 1024,
    );
    const size = 11 * 1024 * 1024;
    await disk.putStream(
      'big.bin',
      Stream.fromIterable([
        for (var i = 0; i < size ~/ 65536; i++) List.filled(65536, i % 251),
      ]),
    );
    expect(await disk.size('big.bin'), size);
    var offset = 0;
    var mismatch = false;
    await for (final chunk in disk.readStream('big.bin')) {
      for (final byte in chunk) {
        if (byte != (offset ~/ 65536) % 251) {
          mismatch = true;
        }
        offset++;
      }
    }
    expect(offset, size);
    expect(mismatch, isFalse);
  });

  test('presigned GET and PUT against the server', () async {
    disk = S3Disk(
      's3',
      S3Disk.fromConfig('s3', config).client,
      root: 'run-${Random().nextInt(1 << 32)}',
    );
    final upload = disk.temporaryUploadUrl(
      'direct.txt',
      expiration: DateTime.now().add(const Duration(minutes: 5)),
      contentType: 'text/plain',
    );
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final put = await http.openUrl('PUT', Uri.parse(upload.url));
    upload.headers.forEach(put.headers.set);
    put.contentLength = 6;
    put.write('direct');
    final putResponse = await put.close();
    await putResponse.drain<void>();
    expect(putResponse.statusCode, 200);

    final get = await http.getUrl(
      Uri.parse(
        disk.temporaryUrl(
          'direct.txt',
          expiration: DateTime.now().add(const Duration(minutes: 5)),
        ),
      ),
    );
    final response = await get.close();
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), 'direct');
  });
}
