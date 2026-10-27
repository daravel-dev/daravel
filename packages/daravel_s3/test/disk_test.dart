import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_s3/daravel_s3.dart';
import 'package:test/test.dart';

import 'support/disk_contract.dart';
import 'support/fake_s3.dart';
import 'support/post_form.dart';

void main() {
  group('MemoryDisk (reference)', () {
    diskContract(() async => MemoryDisk('memory'));
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

    /// A client with a short timeout and no wait between retries.
    S3Client quick({
      int retries = 3,
      Duration timeout = const Duration(milliseconds: 300),
    }) => S3Client(
      signer: s3.signer,
      bucket: s3.bucket,
      endpoint: s3.endpoint,
      pathStyle: true,
      timeout: timeout,
      retries: retries,
      retryDelay: Duration.zero,
    );

    test('503 SlowDown, 500 and a dropped connection are retried', () async {
      var faults = 0;
      s3.fault = (request) async {
        if (faults++ >= 3) {
          return false;
        }
        await request.drain<void>();
        if (faults == 3) {
          // A reset mid-request.
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return true;
        }
        request.response
          ..statusCode = faults == 1 ? 503 : 500
          ..write(
            '<Error><Code>${faults == 1 ? 'SlowDown' : 'InternalError'}</Code>'
            '<Message>try again</Message></Error>',
          );
        await request.response.close();
        return true;
      };
      final client = quick();
      addTearDown(client.close);
      await client.putObject('retried.txt', utf8.encode('ok'));
      expect(s3.objects['retried.txt']!.bytes, utf8.encode('ok'));
      expect(s3.log.where((l) => l == 'PUT /bucket/retried.txt'), hasLength(4));

      // Exhausted: the last answer is the error, with S3's code.
      faults = -100;
      await expectLater(
        quick(retries: 1).putObject('never.txt', [1]),
        throwsA(
          isA<S3Exception>().having((e) => e.code, 'code', 'InternalError'),
        ),
      );
      expect(client.backoff(0).inMicroseconds, 0, reason: 'no delay here');
      final real = S3Client(signer: s3.signer, bucket: 'b');
      expect(real.backoff(0).inMilliseconds, inInclusiveRange(50, 100));
      expect(real.backoff(2).inMilliseconds, inInclusiveRange(200, 400));
      expect(real.backoff(30).inSeconds, inInclusiveRange(10, 20));
      expect(real.backoff(90).inSeconds, inInclusiveRange(10, 20));
    });

    test('a request that times out is aborted, 4xx is not retried', () async {
      var stalled = 0;
      s3.fault = (request) async {
        if (request.uri.path.endsWith('/stall.txt')) {
          stalled++;
          await request.drain<void>();
          // Never answer; the client gives up and aborts.
          await Future<void>.delayed(const Duration(seconds: 2));
          request.response.statusCode = 200;
          await request.response.close();
          return true;
        }
        return false;
      };
      final client = quick();
      addTearDown(client.close);
      final watch = Stopwatch()..start();
      await expectLater(
        client.putObject('stall.txt', [1]),
        throwsA(
          isA<ConnectionException>()
              .having((e) => e.isTimeout, 'isTimeout', isTrue)
              .having((e) => e.message, 'message', contains('timed out')),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(stalled, 1, reason: 'a timeout is not retried');
      // Not retryable: one request, S3's answer as it came.
      await expectLater(client.getObject('missing-but-ok'), completion(isNull));
      await expectLater(
        client.send('GET', '', query: const {'nope': '1'}, accept: const {418}),
        throwsA(isA<S3Exception>()),
      );
    });

    test('a body that goes quiet is cut off, not held for ever', () async {
      s3.fault = (request) async {
        if (request.uri.path.endsWith('/quiet.bin') &&
            request.method == 'GET') {
          await request.drain<void>();
          final response = request.response
            ..statusCode = 200
            ..contentLength = 100
            ..add(List.filled(10, 1));
          await response.flush();
          // The rest never comes.
          await Future<void>.delayed(const Duration(seconds: 2));
          try {
            await response.close();
          } on Object {
            // Already gone.
          }
          return true;
        }
        return false;
      };
      final client = quick();
      addTearDown(client.close);
      final watch = Stopwatch()..start();
      await expectLater(
        S3Disk('s3', client).getBytes('quiet.bin'),
        throwsA(
          isA<ConnectionException>().having(
            (e) => e.isTimeout,
            'isTimeout',
            isTrue,
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
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

    group('temporaryUploadForm (POST policy)', () {
      DateTime soon() => DateTime.now().add(const Duration(minutes: 15));

      test('the policy carries every field and the conditions', () {
        final form = disk.temporaryUploadForm(
          'materials/a.mp4',
          expiration: soon(),
          maxSize: 1000,
          contentTypePrefix: 'video/',
        );
        expect(form.url, '${s3.endpoint}/bucket');
        expect(form.fields['key'], 'materials/a.mp4');
        expect(form.fields, isNot(contains('Content-Type')));
        final policy = jsonDecode(
          utf8.decode(base64.decode(form.fields['policy']!)),
        ) as Map<String, Object?>;
        expect(
          policy['expiration'],
          matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')),
        );
        expect(policy['conditions'], [
          {'bucket': 'bucket'},
          ['content-length-range', 0, 1000],
          ['starts-with', r'$Content-Type', 'video/'],
          {'key': 'materials/a.mp4'},
          {'x-amz-algorithm': 'AWS4-HMAC-SHA256'},
          {'x-amz-credential': form.fields['x-amz-credential']},
          {'x-amz-date': form.fields['x-amz-date']},
        ]);
      });

      test('uploads a file within the limits', () async {
        final form = disk.temporaryUploadForm(
          'materials/a.mp4',
          expiration: soon(),
          maxSize: 1000,
          contentTypePrefix: 'video/',
        );
        final response = await postForm(form.url, {
          ...form.fields,
          'Content-Type': 'video/mp4',
        }, List.filled(1000, 1));
        expect(response.status, 204, reason: response.body);
        expect(await disk.size('materials/a.mp4'), 1000);
        expect(s3.objects['materials/a.mp4']!.type, 'video/mp4');
      });

      test('rejects a file over maxSize', () async {
        final form = disk.temporaryUploadForm(
          'big.bin',
          expiration: soon(),
          maxSize: 1000,
        );
        final response = await postForm(
          form.url,
          form.fields,
          List.filled(1001, 1),
        );
        expect(response.status, 400);
        expect(response.body, contains('EntityTooLarge'));
        expect(await disk.exists('big.bin'), isFalse);
      });

      test('rejects another content type, key or an extra field', () async {
        final form = disk.temporaryUploadForm(
          'img/a.png',
          expiration: soon(),
          maxSize: 100,
          contentTypePrefix: 'image/',
        );
        for (final tampered in [
          {...form.fields, 'Content-Type': 'text/html'},
          {...form.fields, 'key': 'img/other.png', 'Content-Type': 'image/png'},
          {...form.fields, 'Content-Type': 'image/png', 'acl': 'public-read'},
        ]) {
          final response = await postForm(form.url, tampered, [1, 2, 3]);
          expect(response.status, 403, reason: '$tampered');
        }
        expect(s3.objects, isEmpty);
      });

      test('an exact content type is a signed field', () async {
        final form = disk.temporaryUploadForm(
          'doc.pdf',
          expiration: soon(),
          contentType: 'application/pdf',
        );
        expect(form.fields['Content-Type'], 'application/pdf');
        final response = await postForm(form.url, form.fields, [1]);
        expect(response.status, 204, reason: response.body);
      });

      test('an expired policy is refused', () async {
        Clock.fake(DateTime.now().subtract(const Duration(hours: 1)));
        addTearDown(Clock.restore);
        final form = disk.temporaryUploadForm(
          'late.bin',
          expiration: Clock.now().add(const Duration(minutes: 5)),
        );
        Clock.restore();
        final response = await postForm(form.url, form.fields, [1]);
        expect(response.status, 403);
        expect(response.body, contains('expired'));
      });

      test('arguments are checked', () {
        expect(
          () => disk.temporaryUploadForm(
            'a',
            expiration: soon(),
            contentType: 'a/b',
            contentTypePrefix: 'a/',
          ),
          throwsArgumentError,
        );
        expect(
          () => disk.temporaryUploadForm(
            'a',
            expiration: soon(),
            maxSize: 5,
            minSize: 10,
          ),
          throwsArgumentError,
        );
      });
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
