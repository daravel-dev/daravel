import 'dart:convert';
import 'dart:io';

import 'package:dartisan_cli/src/client_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dispositionFilename` in the generated client's runtime gives a name to
/// save under, never a path: the part after the last `/` or `\`, without
/// control characters, and `null` when nothing safe is left.
void main() {
  late Map<String, Object?> results;

  const headers = <String>[
    "attachment; filename*=UTF-8''..%2F..%2Fetc%2Fpasswd",
    'attachment; filename="../../.ssh/authorized_keys"',
    r'attachment; filename="..\\..\\evil.exe"',
    "attachment; filename*=UTF-8''..%5C..%5Cevil.exe",
    "attachment; filename*=UTF-8''shell.sh%00.png",
    'attachment; filename="a\tb\r\nc.txt"',
    'attachment; filename=".."',
    'attachment; filename="."',
    "attachment; filename*=UTF-8''..",
    "attachment; filename*=UTF-8''dir%2F",
    'attachment; filename=""',
    'attachment; filename="  "',
    'attachment; filename="/"',
    "attachment; filename*=UTF-8''%00",
    // Unchanged: plain names.
    'attachment; filename=a.xlsx',
    r'attachment; filename="a \"b\"; c.csv"',
    "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
    "attachment; filename*=UTF-8''%E0%A4; filename=x",
    'attachment; filename="..report.csv"',
  ];

  setUpAll(() async {
    // The function as generated clients carry it, run on its own.
    final source = clientRuntimeSource;
    final start = source.indexOf('String? dispositionFilename(');
    final end = source.indexOf('\n/// A page from', start);
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final dir = Directory.systemTemp.createTempSync('disposition');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File(p.join(dir.path, 'main.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

${source.substring(start, end)}

void main() {
  final headers = (jsonDecode(stdin.readLineSync()!) as List).cast<String>();
  stdout.write(jsonEncode({for (final h in headers) h: dispositionFilename(h)}));
}
''');
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      script.path,
    ]);
    process.stdin.writeln(jsonEncode(headers));
    await process.stdin.close();
    final out = await utf8.decodeStream(process.stdout);
    final err = await utf8.decodeStream(process.stderr);
    expect(await process.exitCode, 0, reason: err);
    results = (jsonDecode(out) as Map).cast<String, Object?>();
  });

  test('paths become the name after the last separator', () {
    expect(results[headers[0]], 'passwd');
    expect(results[headers[1]], 'authorized_keys');
    expect(results[headers[2]], 'evil.exe');
    expect(results[headers[3]], 'evil.exe');
  });

  test('control characters are left out', () {
    expect(results[headers[4]], 'shell.sh.png');
    expect(results[headers[5]], 'abc.txt');
  });

  test('nothing safe left: null', () {
    for (final header in headers.sublist(6, 14)) {
      expect(results[header], isNull, reason: header);
    }
  });

  test('plain names are as before', () {
    expect(results[headers[14]], 'a.xlsx');
    expect(results[headers[15]], 'a "b"; c.csv');
    expect(results[headers[16]], 'résumé.pdf');
    expect(results[headers[17]], 'x');
    expect(results[headers[18]], '..report.csv');
  });
}
