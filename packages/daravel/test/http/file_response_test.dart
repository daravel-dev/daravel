import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/file_response.dart' show matchesIfNoneMatch;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> text(Response response) async {
  final body = response.body as StreamBody;
  return utf8.decode(await body.stream.expand((chunk) => chunk).toList());
}

void main() {
  // RFC 9110 §8.8.3: etagc = %x21 / %x23-7E / obs-text (%x80-FF).
  String etagc(Random random) {
    final pick = random.nextInt(10);
    if (pick == 0) {
      return ',';
    }
    if (pick == 1) {
      return '*';
    }
    if (pick == 2) {
      return String.fromCharCode(0x80 + random.nextInt(0x80));
    }
    final unit = 0x21 + random.nextInt(0x7E - 0x21 + 1);
    return String.fromCharCode(unit == 0x22 ? 0x21 : unit);
  }

  String opaque(Random random) =>
      '"${List.generate(random.nextInt(12), (_) => etagc(random)).join()}"';

  String ows(Random random) =>
      [' ', '\t', '', ''][random.nextInt(4)] * random.nextInt(3);

  test('500 seeded If-None-Match values read by RFC 9110: a tag matches '
      'itself in any list, and nothing but a lone * matches a tag it does '
      'not hold', () {
    for (var seed = 0; seed < 500; seed++) {
      final random = Random(seed);
      final current = opaque(random);
      final etag = random.nextBool() ? current : 'W/$current';
      final members = <String>[];
      var holds = false;
      for (var i = random.nextInt(6); i >= 0; i--) {
        final tag = random.nextInt(4) == 0 ? current : opaque(random);
        holds |= tag == current;
        members.add('${random.nextBool() ? 'W/' : ''}$tag');
        if (random.nextInt(5) == 0) {
          members.add(''); // An empty member, which is skipped.
        }
      }
      final value = members
          .map((m) => '${ows(random)}$m${ows(random)}')
          .join(',');
      final reason = 'seed $seed: $value against $etag';
      // (P1) and (P2): it matches exactly when the list holds the tag.
      expect(matchesIfNoneMatch(value, etag), holds, reason: reason);
      // Garbage around it never matches: an unquoted member, a stray
      // quote, or a * in a list.
      for (final broken in [
        '$value, x',
        '$value, "',
        '$value, *',
        '*, $value',
        '$value, W/*',
      ]) {
        expect(
          matchesIfNoneMatch(broken, etag),
          isFalse,
          reason: '$reason / $broken',
        );
      }
    }
    expect(matchesIfNoneMatch(' * ', '"x"'), isTrue);
  });

  test('the five shapes found in review', () {
    // A comma inside the quotes is part of the tag.
    expect(matchesIfNoneMatch('"a,b"', '"a,b"'), isTrue);
    // A * inside a list does not match anything.
    expect(matchesIfNoneMatch('"foo,*,bar"', '"current"'), isFalse);
    expect(matchesIfNoneMatch('"foo", *, "bar"', '"current"'), isFalse);
    // W/* is no entity tag.
    expect(matchesIfNoneMatch('W/*', '"current"'), isFalse);
    // W/ is case-sensitive.
    expect(matchesIfNoneMatch('w/"current"', '"current"'), isFalse);
    // A value that does not read as one matches nothing.
    expect(matchesIfNoneMatch('current', 'current'), isFalse);
  });

  test('CI reports entity tag matching costs', () {
    final cases = <String, String>{
      'long-value': '"${'a' * (1024 * 1024)}"',
      'distinct-values': List.generate(10000, (i) => '"tag$i"').join(','),
      'many-items': List.filled(10000, '"other"').join(','),
    };
    for (final entry in cases.entries) {
      final timer = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        expect(matchesIfNoneMatch(entry.value, '"current"'), isFalse);
      }
      timer.stop();
      print(
        'etag ${entry.key}: ${entry.value.length} bytes, 20 runs, ${timer.elapsedMicroseconds} us',
      );
    }
  }, skip: Platform.environment['CI'] != 'true' ? 'CI timing only' : false);
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

    test('If-None-Match sent on two lines is read as one list (RFC 9110 '
        '§5.3)', () async {
      final etag = (await Response.file(
        file.path,
        request: get(),
      )).headers.first('etag')!;
      final request = get()
        ..headers.add('if-none-match', '"other"')
        ..headers.add('if-none-match', etag);
      expect((await Response.file(file.path, request: request)).status, 304);
      // A * on a line of its own beside a tag is no lone *: not matched.
      final mixed = get()
        ..headers.add('if-none-match', '"other"')
        ..headers.add('if-none-match', '*');
      expect((await Response.file(file.path, request: mixed)).status, 200);
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

    test('If-None-Match accepts weak tags, lists and wildcard', () async {
      final first = await Response.file(file, request: get());
      final etag = first.headers.first('etag')!;
      for (final value in ['W/$etag', '"other", $etag', '*']) {
        expect(
          (await Response.file(
            file,
            request: get({'if-none-match': value}),
          )).status,
          304,
          reason: value,
        );
      }
      expect(
        (await Response.file(
          file,
          request: get({'if-none-match': '"other"'}),
        )).status,
        200,
      );
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
