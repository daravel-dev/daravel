import 'dart:io';

import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List<String> rulesOf(List<LintIssue> issues) =>
    issues.map((i) => i.rule).toList();

void main() {
  test('no_dart_mirrors flags imports anywhere', () {
    final issues = lintSource(
      "import 'dart:mirrors';\nvoid main() {}\n",
      'bin/x.dart',
    );
    expect(rulesOf(issues), ['no_dart_mirrors']);
    expect(issues.single.line, 1);
  });

  test('no_print_in_app only in lib/ and only bare print', () {
    const source = '''
void f() {
  print('x');
  logger.print('ok');
  // daravel-lint-ignore: no_print_in_app
  print('allowed');
}
''';
    final issues = lintSource(source, 'lib/app/a.dart');
    expect(rulesOf(issues), ['no_print_in_app']);
    expect(issues.single.line, 2);
    expect(lintSource(source, 'tool/a.dart'), isEmpty);
  });

  test(
    'no_mutable_static_in_app flags mutable statics and globals in lib/app',
    () {
      const source = '''
var counter = 0;
final ok = 1;
class A {
  static int hits = 0;
  static final cache = <String, int>{};
  static const limit = 3;
  int instance = 0;
  static int get computed => 1;
}
''';
      final issues = lintSource(source, 'lib/app/services/a.dart');
      expect(rulesOf(issues), [
        'no_mutable_static_in_app',
        'no_mutable_static_in_app',
      ]);
      expect(issues.map((i) => i.line), [1, 4]);
      expect(lintSource(source, 'lib/src/a.dart'), isEmpty);
    },
  );

  test(
    'no_sql_string_interpolation flags interpolated and concatenated SQL',
    () {
      const source = r'''
Future<void> f(String name, int id) async {
  await DB.select('SELECT * FROM users WHERE name = ?', [name]);
  await DB.select('SELECT * FROM users WHERE name = $name');
  await db.statement('DELETE FROM t WHERE id = ' + id.toString());
  query.whereRaw('lower(email) = ${name.toLowerCase()}');
  final e = RawExpression('count(${name})');
  query.orderByRaw('created_at desc');
  other.select('$name'); // daravel-lint-ignore: no_sql_string_interpolation
}
''';
      final issues = lintSource(source, 'lib/app/repo.dart');
      expect(rulesOf(issues), List.filled(4, 'no_sql_string_interpolation'));
      expect(issues.map((i) => i.line), [3, 4, 5, 6]);
      expect(issues.first.toString(), startsWith('lib/app/repo.dart:3:'));
    },
  );

  test('lintProject walks the project and checks registries', () async {
    final root = await Directory.systemTemp.createTemp('daravel_lints_');
    addTearDown(() => root.delete(recursive: true));
    void write(String path, String content) {
      final file = File(p.join(root.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    write('lib/app/models/user.dart', 'class User { static var count = 0; }\n');
    write('lib/app/jobs/send_mail.dart', 'class SendMail {}\n');
    write('lib/app/jobs/orphan.dart', 'class Orphan {}\n');
    write('database/migrations/m_1_create_users.dart', 'class M {}\n');
    write(
      'bootstrap/jobs.dart',
      "import 'package:demo/app/jobs/send_mail.dart';\n",
    );
    write(
      'bootstrap/migrations.dart',
      "import '../database/migrations/m_1_create_users.dart';\n",
    );
    write(
      'test/ignored_test.dart',
      "void main() { print('fine in tests'); }\n",
    );

    final issues = lintProject(root.path);
    expect(rulesOf(issues), [
      'no_mutable_static_in_app',
      'registry_entry_missing',
    ]);
    expect(issues.last.path, 'lib/app/jobs/orphan.dart');
    expect(issues.last.message, contains('bootstrap/jobs.dart'));
  });
}
