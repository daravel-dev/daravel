import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Application app;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          api: (r) {
            r
                .post('/upload', (req) async {
                  final data = req.validated();
                  return {'name': data.file('doc').clientName};
                })
                .rules(const {
                  'doc': 'required|file|mimes:pdf,docx|max:2',
                  'photo': 'nullable|image|max:1',
                  'gallery': 'sometimes|array',
                  'gallery.*': 'image',
                  'sheet': 'nullable|extensions:csv,txt',
                  'clip': 'nullable|mimetypes:image/*',
                });
          },
        )
        .create();
    await app.boot();
  });
  tearDown(() => app.shutdown());

  Future<(int, Map<String, Object?>)> upload(Map<String, Object> files) async {
    final response = await app.handle(
      Request.fake(method: 'POST', path: '/api/upload', files: files),
    );
    return (
      response.status,
      jsonDecode(await response.bodyText()) as Map<String, Object?>,
    );
  }

  UploadedFile pdf(String name, {int padding = 0}) => UploadedFile.fromBytes([
    ...utf8.encode('%PDF-1.7\n'),
    ...Uint8List(padding),
  ], name: name);

  test('valid uploads pass and reach validated()', () async {
    final (status, body) = await upload({
      'doc': pdf('report.pdf'),
      'photo': UploadedFile.fake.image('me.png'),
      'gallery': [
        UploadedFile.fake.image('a.png'),
        UploadedFile.fake.image('b.gif'),
      ],
      'sheet': UploadedFile.fake.withContent('data.csv', 'a,b\n1,2'),
      'clip': UploadedFile.fake.image('c.png'),
    });
    expect(status, 200, reason: '$body');
    expect(body['name'], 'report.pdf');
  });

  test("Laravel's messages and rules", () async {
    final (status, body) = await upload({
      'doc': UploadedFile.fake.withContent('fake.pdf', 'not a pdf'),
      'photo': UploadedFile.fake.image('big.png', kilobytes: 2),
      'gallery': [UploadedFile.fake.withContent('x.png', 'text')],
      'sheet': UploadedFile.fake.withContent('data.xls', 'a'),
      'clip': pdf('x.pdf'),
    });
    expect(status, 422);
    final errors = body['errors']! as Map<String, Object?>;
    expect(errors['doc'], ['The doc field must be a file of type: pdf, docx.']);
    expect(errors['photo'], [
      'The photo field must not be greater than 1 kilobytes.',
    ]);
    expect(errors['gallery.0'], ['The gallery.0 field must be an image.']);
    expect(errors['sheet'], [
      'The sheet field must have one of the following extensions: csv, txt.',
    ]);
    expect(errors['clip'], ['The clip field must be a file of type: image/*.']);
  });

  test(
    'sizes are kilobytes; PHP uploads are refused; text is not a file',
    () async {
      var (status, body) = await upload({'doc': pdf('big.pdf', padding: 3000)});
      expect(status, 422);
      expect((body['errors']! as Map)['doc'], [
        'The doc field must not be greater than 2 kilobytes.',
      ]);
      (status, body) = await upload({'doc': pdf('shell.php')});
      expect(
        status,
        422,
        reason: 'PHP files are refused even with PDF content',
      );

      final notFile = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/upload',
          json: const {'doc': 'x'},
        ),
      );
      expect(notFile.status, 422);
      expect(
        await notFile.bodyText(),
        contains('The doc field must be a file.'),
      );
    },
  );

  test('SVG is an image only with image:allow_svg', () async {
    final svg = UploadedFile.fake.withContent('i.svg', '<svg xmlns="x"/>');
    expect(await Validator({'i': svg}, const {'i': 'image'}).fails(), isTrue);
    expect(
      await Validator({'i': svg}, const {'i': 'image:allow_svg'}).passes(),
      isTrue,
    );
  });
}
