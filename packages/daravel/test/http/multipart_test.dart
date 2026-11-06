import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/multipart.dart';
import 'package:test/test.dart';

void main() {
  group('content type detection (never from the name)', () {
    test('images, documents and text', () {
      final png = UploadedFile.fake.image('a.png');
      expect(png.mimeType, 'image/png');
      expect(png.extension, 'png');
      expect(UploadedFile.fake.image('b.gif').mimeType, 'image/gif');
      expect(
        UploadedFile.fake.withContent('notes.png', 'just text').mimeType,
        'text/plain',
        reason: 'a text file named .png is not an image',
      );
      expect(
        UploadedFile.fake
            .withContent('x.svg', '<?xml version="1.0"?><svg/>')
            .mimeType,
        'image/svg+xml',
      );
      expect(
        UploadedFile.fake.withContent('r.pdf', '%PDF-1.7\n...').extension,
        'pdf',
      );
      final docx = Uint8List.fromList([
        0x50, 0x4B, 0x03, 0x04, // zip
        ...'[Content_Types].xml word/document.xml'.codeUnits,
      ]);
      expect(UploadedFile.fromBytes(docx, name: 'cv.docx').extension, 'docx');
      expect(
        UploadedFile.fake.create('empty.bin').mimeType,
        'application/x-empty',
      );
      expect(
        UploadedFile.fromBytes(const [0, 1, 2, 3, 255], name: 'x.jpg').mimeType,
        'application/octet-stream',
      );
    });

    test('hashName keeps the detected extension', () {
      final name = UploadedFile.fake.image('photo.PNG').hashName('avatars');
      expect(name, matches(RegExp(r'^avatars/[A-Za-z0-9]{40}\.png$')));
    });
  });

  group('multipart requests', () {
    late Application app;
    late Directory base;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_upload');
      app = Application.configure(basePath: base.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) {
              r.post('/avatar', (req) async {
                final file = (await req.file('avatar'))!;
                final path = await file.store('avatars');
                final all = await req.all();
                return {
                  'name': all['name'],
                  'client': file.clientName,
                  'size': file.size,
                  'type': file.mimeType,
                  'stored': path,
                  'photos': (all['photos'] as List?)?.length,
                  'has': await req.hasFile('photos'),
                  'temp': file.path,
                };
              });
            },
          )
          .create();
      await app.boot();
    });
    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    test('fields, files and lists arrive like Laravel\'s', () async {
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/avatar',
          form: const {'name': 'Ana'},
          files: {
            'avatar': UploadedFile.fake.image('me.png', kilobytes: 3),
            'photos': [
              UploadedFile.fake.image('1.png'),
              UploadedFile.fake.image('2.gif'),
            ],
          },
        ),
      );
      expect(response.status, 200);
      final body = await response.bodyText();
      expect(body, contains('"name":"Ana"'));
      expect(body, contains('"client":"me.png"'));
      expect(body, contains('"size":3072'));
      expect(body, contains('"type":"image/png"'));
      expect(body, contains('"photos":2'));
      expect(body, contains('"has":true'));
      final stored = RegExp(r'"stored":"([^"]+)"').firstMatch(body)!.group(1)!;
      expect(
        File('${base.path}/storage/app/private/$stored').lengthSync(),
        3072,
      );
    });

    test('temporary files are deleted when the request ends', () async {
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/avatar',
          files: {'avatar': UploadedFile.fake.image('me.png')},
        ),
      );
      final body = await response.bodyText();
      final temp =
          (jsonDecode(body) as Map<String, Object?>)['temp']! as String;
      expect(temp, contains('daravel-uploads'));
      expect(File(temp).existsSync(), isFalse);
    });

    test('a body over the limit answers 413', () async {
      final request = Request.fake(
        method: 'POST',
        path: '/api/avatar',
        files: {'avatar': UploadedFile.fake.create('big.bin', kilobytes: 64)},
      )..maxBodyBytes = 10 * 1024;
      expect((await app.handle(request)).status, 413);
    });

    test('a malformed body answers 400 instead of hanging', () async {
      const boundary = 'b';
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/avatar',
          // A bare CR inside a part header.
          body:
              '--$boundary\r\nContent-Disposition: form-data; '
              'name="x"\rbroken\r\n\r\nv\r\n--$boundary--\r\n',
          headers: const {
            'content-type': 'multipart/form-data; boundary=$boundary',
            'accept': 'application/json',
          },
        ),
      );
      expect(response.status, 400);
    });
  });

  group('a body that ends or fails inside a part (#145)', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('daravel_mp_cut'));
    tearDown(() => temp.deleteSync(recursive: true));

    const boundary = 'cut';
    final fileHead = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="title"\r\n\r\n'
      'Report\r\n--$boundary\r\nContent-Disposition: form-data; '
      'name="doc"; filename="a.bin"\r\nContent-Type: application/pdf'
      '\r\n\r\n',
    );
    final fieldHead = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="note"\r\n\r\n',
    );

    /// Sends [chunks] and then ends the body with [end]: an error, or
    /// `null` for a plain end without the closing boundary.
    Future<MultipartBody> parse(List<List<int>> chunks, Object? end) {
      final body = StreamController<List<int>>();
      unawaited(() async {
        for (final chunk in chunks) {
          body.add(chunk);
          await Future<void>.delayed(Duration.zero);
        }
        if (end != null) {
          body.addError(end);
        }
        await body.close();
      }());
      return parseMultipart(body.stream, boundary, tempDirectory: temp)
      // A hang fails here instead of at the test timeout.
      .timeout(const Duration(seconds: 10));
    }

    final file = List<int>.filled(64 * 1024, 7);

    test('a connection error inside a file answers 400', () async {
      await expectLater(
        parse([fileHead, file], const SocketException('reset')),
        throwsA(
          isA<BadRequestHttpException>().having(
            (e) => e.message,
            'message',
            'Unexpected end of multipart body.',
          ),
        ),
      );
      expect(temp.listSync(), isEmpty, reason: 'the partial file is gone');
    });

    test('an end inside a file answers 400', () async {
      await expectLater(
        parse([fileHead, file], null),
        throwsA(isA<BadRequestHttpException>()),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('an end inside a field answers 400', () async {
      await expectLater(
        parse([fieldHead, utf8.encode('half a val')], null),
        throwsA(isA<BadRequestHttpException>()),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('the body limit inside a file stays a 413', () async {
      await expectLater(
        parse([fileHead, file], const PayloadTooLargeHttpException()),
        throwsA(isA<PayloadTooLargeHttpException>()),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('files written before the cut are deleted too', () async {
      await expectLater(
        parse([
          fileHead,
          file,
          utf8.encode('\r\n'),
          utf8.encode(
            '--$boundary\r\nContent-Disposition: form-data; name="b"; '
            'filename="b.bin"\r\n\r\n',
          ),
          file,
        ], null),
        throwsA(isA<BadRequestHttpException>()),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('a complete body in any chunking still parses', () async {
      final content = List<int>.filled(3000, 7);
      final whole = <int>[
        ...fileHead,
        ...content,
        ...utf8.encode('\r\n--$boundary--\r\n'),
      ];
      for (final size in [1, 7, 1000, whole.length]) {
        // Synchronous chunks: the parts and their ends arrive back to back.
        final result = await parseMultipart(
          Stream.fromIterable([
            for (var i = 0; i < whole.length; i += size)
              whole.sublist(i, (i + size).clamp(0, whole.length)),
          ]),
          boundary,
          tempDirectory: temp,
        ).timeout(const Duration(seconds: 10));
        expect(result.fields['title'], 'Report');
        expect(result.files.single.size, content.length);
        for (final upload in result.files) {
          await upload.delete();
        }
      }
    });
  });
}
