import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_s3/daravel_s3.dart';
import 'package:test/test.dart';

import 'support/disk_contract.dart';
import 'support/fake_s3.dart';

void main() {
  group('MemoryDisk (reference)', () {
    diskContract(() async => MemoryDisk('memory'), refusesRootDelete: false);
  });

  group('LocalDisk (reference)', () {
    late Directory temp;
    tearDown(() => temp.delete(recursive: true));
    diskContract(() async {
      temp = await Directory.systemTemp.createTemp('daravel_s3_');
      return LocalDisk('local', temp.path);
    });
  });

  group('S3Disk', () {
    late FakeS3 s3;
    tearDown(() => s3.close());
    diskContract(() async {
      s3 = await FakeS3.start();
      // Small parts so the contract's 39 KB stream goes multipart.
      return S3Disk(
        's3',
        S3Disk.fromConfig('s3', s3.config()).client,
        partSize: 8 * 1024,
      );
    });
  });

  group('S3Disk on the wire', () {
    late FakeS3 s3;
    late S3Disk disk;

    setUp(() async {
      s3 = await FakeS3.start();
      disk = S3Disk.fromConfig('s3', s3.config());
    });
    tearDown(() async {
      disk.client.close();
      await s3.close();
    });

    test('objects get a content type from their extension', () async {
      await disk.put('img/logo.png', [1, 2, 3]);
      await disk.put('data.unknownext', 'x');
      expect(s3.objects['img/logo.png']!.type, 'image/png');
      expect(s3.objects['data.unknownext']!.type, 'application/octet-stream');
    });

    test('a small stream is one PUT, a large one a multipart upload', () async {
      final small = S3Disk('s3', disk.client, partSize: 1024);
      await small.putStream('small.bin', Stream.value(List.filled(1000, 7)));
      expect(s3.log.last, 'PUT /bucket/small.bin');
      expect(s3.log.where((l) => l.contains('uploads')), isEmpty);

      s3.log.clear();
      await small.putStream(
        'large.bin',
        Stream.fromIterable([for (var i = 0; i < 5; i++) List.filled(700, i)]),
      );
      expect(s3.log.first, 'POST /bucket/large.bin?uploads=');
      final parts = s3.log.where((l) => l.contains('partNumber')).toList();
      expect(parts, hasLength(4)); // 1024 + 1024 + 1024 + 428 bytes
      expect(s3.log.last, startsWith('POST /bucket/large.bin?uploadId='));
      expect(await small.size('large.bin'), 3500);
    });

    test('a failing stream aborts its multipart upload', () async {
      final small = S3Disk('s3', disk.client, partSize: 1024);
      Stream<List<int>> failing() async* {
        yield List.filled(2048, 1);
        throw StateError('client went away');
      }

      await expectLater(
        small.putStream('broken.bin', failing()),
        throwsStateError,
      );
      expect(s3.log.last, startsWith('DELETE /bucket/broken.bin?uploadId='));
      expect(s3.objects, isNot(contains('broken.bin')));
    });

    test('delete sends one DeleteObjects per thousand keys', () async {
      final paths = [for (var i = 0; i < 1001; i++) 'many/$i.txt'];
      for (final path in paths) {
        s3.objects[path] = (
          bytes: Uint8List(0),
          modified: DateTime.now().toUtc(),
          type: 'text/plain',
        );
      }
      s3.log.clear();
      expect(await disk.delete(paths), isTrue);
      expect(s3.log.where((l) => l.startsWith('POST')), [
        'POST /bucket?delete=',
        'POST /bucket?delete=',
      ]);
      expect(s3.objects, isEmpty);
    });

    test('copy is server side', () async {
      await disk.put('a.txt', 'a');
      s3.log.clear();
      await disk.copy('a.txt', 'b.txt');
      expect(s3.log, ['PUT /bucket/b.txt']);
    });

    test('a root prefixes every key and is hidden from listings', () async {
      final rooted = S3Disk.fromConfig('s3', s3.config(root: 'tenant-1'));
      await rooted.put('docs/a.txt', 'a');
      expect(s3.objects.keys, ['tenant-1/docs/a.txt']);
      expect(await rooted.allFiles(), ['docs/a.txt']);
      expect(await rooted.directories(), ['docs']);
      rooted.client.close();
    });

    test(
      'a directory Laravel made (an empty dir/ object) is a directory',
      () async {
        s3.objects['from-laravel/'] = (
          bytes: Uint8List(0),
          modified: DateTime.now().toUtc(),
          type: 'application/x-directory',
        );
        expect(await disk.directories(), ['from-laravel']);
        expect(await disk.allFiles(), isEmpty);
      },
    );

    test('url points at the bucket, or at AWS_URL', () async {
      expect(disk.url('a b/c.txt'), '${s3.endpoint}/bucket/a%20b/c.txt');
      final cdn = S3Disk.fromConfig(
        's3',
        s3.config(url: 'https://cdn.example.com/', root: 'public'),
      );
      expect(
        cdn.url('a b/c.txt'),
        'https://cdn.example.com/public/a%20b/c.txt',
      );
    });

    test('a temporary URL downloads a private object', () async {
      await disk.put('private/report.pdf', 'secret report');
      final url = disk.temporaryUrl(
        'private/report.pdf',
        expiration: DateTime.now().add(const Duration(minutes: 5)),
        responseContentDisposition: 'attachment; filename="rapor.pdf"',
      );
      final response = await _send('GET', url);
      expect(response.status, 200, reason: response.body);
      expect(response.body, 'secret report');

      final tampered = url.replaceFirst('report.pdf', 'other.pdf');
      expect((await _send('GET', tampered)).status, 403);
    });

    test(
      'a temporary upload URL accepts the signed content type only',
      () async {
        final upload = disk.temporaryUploadUrl(
          'uploads/video.mp4',
          expiration: DateTime.now().add(const Duration(minutes: 15)),
          contentType: 'video/mp4',
        );
        expect(upload.headers, {'content-type': 'video/mp4'});

        final wrong = await _send(
          'PUT',
          upload.url,
          headers: {'content-type': 'text/html'},
          body: 'x',
        );
        expect(wrong.status, 403);

        final ok = await _send(
          'PUT',
          upload.url,
          headers: upload.headers,
          body: 'movie bytes',
        );
        expect(ok.status, 200, reason: ok.body);
        expect(await disk.get('uploads/video.mp4'), 'movie bytes');
      },
    );

    test('temporary URLs follow the testable clock', () {
      Clock.fake(DateTime.utc(2030, 1, 2, 3, 4, 5));
      addTearDown(Clock.restore);
      final url = Uri.parse(
        disk.temporaryUrl(
          'a.txt',
          expiration: DateTime.utc(2030, 1, 2, 3, 34, 5),
        ),
      );
      expect(url.queryParameters['X-Amz-Date'], '20300102T030405Z');
      expect(url.queryParameters['X-Amz-Expires'], '1800');
    });

    test('S3 errors carry S3 codes', () async {
      final wrongKey = S3Disk.fromConfig(
        's3',
        S3Config(
          accessKey: s3.signer.accessKey,
          secretKey: 'not-the-secret',
          region: s3.signer.region,
          bucket: s3.bucket,
          endpoint: s3.endpoint,
          usePathStyleEndpoint: true,
        ),
      );
      await expectLater(
        wrongKey.put('a.txt', 'a'),
        throwsA(
          isA<S3Exception>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.code, 'code', 'SignatureDoesNotMatch'),
        ),
      );
      wrongKey.client.close();
    });
  });
}

Future<({int status, String body})> _send(
  String method,
  String url, {
  Map<String, String> headers = const {},
  String body = '',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse(url));
    headers.forEach(request.headers.set);
    final bytes = utf8.encode(body);
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}
