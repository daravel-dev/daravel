import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
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
}
