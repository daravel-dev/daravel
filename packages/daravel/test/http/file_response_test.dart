import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> text(Response response) async {
  final body = response.body as StreamBody;
  return utf8.decode(await body.stream.expand((chunk) => chunk).toList());
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daravel_file');
    file = File(p.join(dir.path, 'report.pdf'))
      ..writeAsStringSync('0123456789');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Request get([Map<String, String> headers = const {}]) =>
      Request.fake(path: '/x', headers: headers);

  group('contentDisposition', () {
    test('a plain name', () {
      expect(contentDisposition('a.pdf'), 'attachment; filename="a.pdf"');
      expect(
        contentDisposition('a.pdf', inline: true),
        'inline; filename="a.pdf"',
      );
    });

    test('spaces stay readable in the plain form', () {
      expect(
        contentDisposition('laporan akhir.pdf'),
        'attachment; filename="laporan akhir.pdf"',
      );
    });

    test('a non-ASCII name gets filename*', () {
      expect(
        contentDisposition('résumé.pdf'),
        "attachment; filename=\"r_sum_.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
      );
    });

    test('quotes are escaped, percent signs go through filename*', () {
      expect(contentDisposition('a"b.pdf'), r'attachment; filename="a\"b.pdf"');
      expect(
        contentDisposition('100%.pdf'),
        "attachment; filename=\"100_.pdf\"; filename*=UTF-8''100%25.pdf",
      );
    });

    test('paths and control characters are refused', () {
      for (final name in ['', '../a', r'a\b', 'a\r\nx: y', 'a\u0000']) {
        expect(
          () => contentDisposition(name),
          throwsArgumentError,
          reason: name,
        );
      }
    });
  });

  group('Response.file', () {
    test('serves the file with its type and validators', () async {
      final response = await Response.file(file.path, request: get());
      expect(response.status, 200);
      expect(response.headers.first('content-type'), 'application/pdf');
      expect(response.headers.first('accept-ranges'), 'bytes');
      expect(response.headers.first('content-length'), '10');
      expect(response.headers.first('x-content-type-options'), 'nosniff');
      expect(
        response.headers.first('content-disposition'),
        startsWith('inline'),
      );
      expect(await text(response), '0123456789');
    });

    test('a missing file is a 404', () {
      expect(
        Response.file(p.join(dir.path, 'nope')),
        throwsA(isA<NotFoundHttpException>()),
      );
    });

    for (final (range, status, contentRange, body)
        in <(String, int, String, String)>[
          ('bytes=0-3', 206, 'bytes 0-3/10', '0123'),
          ('bytes=4-', 206, 'bytes 4-9/10', '456789'),
          ('bytes=-2', 206, 'bytes 8-9/10', '89'),
          ('bytes=8-100', 206, 'bytes 8-9/10', '89'),
          ('bytes=-100', 206, 'bytes 0-9/10', '0123456789'),
        ]) {
      test(range, () async {
        final response = await Response.file(
          file,
          request: get({'range': range}),
        );
        expect(response.status, status);
        expect(response.headers.first('content-range'), contentRange);
        expect(response.headers.first('content-length'), '${body.length}');
        expect(await text(response), body);
      });
    }

    test('past the end is 416', () async {
      for (final range in ['bytes=10-', 'bytes=100-200', 'bytes=-0']) {
        final response = await Response.file(
          file,
          request: get({'range': range}),
        );
        expect(response.status, 416, reason: range);
        expect(response.headers.first('content-range'), 'bytes */10');
      }
    });

    test('ranges it does not serve give the whole file', () async {
      for (final range in [
        'bytes=0-1,4-5',
        'lines=0-1',
        'bytes=5-2',
        'bytes=-',
      ]) {
        final response = await Response.file(
          file,
          request: get({'range': range}),
        );
        expect(response.status, 200, reason: range);
      }
    });

    test('without a request there are no ranges', () async {
      expect((await Response.file(file)).status, 200);
    });

    test('If-None-Match answers 304', () async {
      final first = await Response.file(file, request: get());
      final etag = first.headers.first('etag')!;
      final second = await Response.file(
        file,
        request: get({'if-none-match': etag}),
      );
      expect(second.status, 304);
    });

    test('a stale If-Range gives the whole file', () async {
      final first = await Response.file(file, request: get());
      final fresh = await Response.file(
        file,
        request: get({
          'range': 'bytes=0-1',
          'if-range': first.headers.first('etag')!,
        }),
      );
      expect(fresh.status, 206);
      final stale = await Response.file(
        file,
        request: get({'range': 'bytes=0-1', 'if-range': '"old"'}),
      );
      expect(stale.status, 200);
    });
  });

  group('Response.download', () {
    test('is an attachment, under the given name', () async {
      final response = await Response.download(file, name: 'laporan.pdf');
      expect(
        response.headers.first('content-disposition'),
        'attachment; filename="laporan.pdf"',
      );
    });

    test('deleteFileAfterSend deletes once it was read', () async {
      final response = await Response.download(file, deleteFileAfterSend: true);
      expect(file.existsSync(), isTrue);
      expect(await text(response), '0123456789');
      expect(file.existsSync(), isFalse);
    });

    test('a file deleted after sending offers no ranges', () async {
      final response = await Response.download(
        file,
        deleteFileAfterSend: true,
        request: get({'range': 'bytes=0-1'}),
      );
      expect(response.status, 200);
      expect(response.headers.first('accept-ranges'), isNull);
      expect(await text(response), '0123456789');
    });

    test('a download nobody reads keeps the file', () async {
      await Response.download(file, deleteFileAfterSend: true);
      expect(file.existsSync(), isTrue);
    });
  });

  group('disks', () {
    late LocalDisk disk;

    setUp(() => disk = LocalDisk('local', dir.path));

    test('download is an attachment', () async {
      final response = await disk.download('report.pdf');
      expect(
        response.headers.first('content-disposition'),
        'attachment; filename="report.pdf"',
      );
      expect(await text(response), '0123456789');
    });

    test('response serves a range', () async {
      final response = await disk.response(
        'report.pdf',
        request: get({'range': 'bytes=2-4'}),
      );
      expect(response.status, 206);
      expect(await text(response), '234');
    });

    test('a range across the chunks of a stream', () async {
      final big = '${'x' * 200000}MARK${'y' * 200000}';
      await disk.put('big.txt', big);
      final response = await disk.response(
        'big.txt',
        request: get({'range': 'bytes=200000-200003'}),
      );
      expect(await text(response), 'MARK');
    });

    test('a missing path is a 404', () {
      expect(disk.download('nope.pdf'), throwsA(isA<NotFoundHttpException>()));
    });
  });
}
