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
  static final Map<String, Object> rules = {'a': 1};
  static final Set<String> seen = Set();
  static final blocked = const <String>[];
  final Map<String, int> perInstance = {};
}
final queue = <int>[];
''';
      final issues = lintSource(source, 'lib/app/services/a.dart');
      expect(rulesOf(issues).toSet(), {'no_mutable_static_in_app'});
      expect(issues.map((i) => i.line), [1, 4, 5, 10, 14]);
      expect(issues.first.message, contains("Cache.store('process')"));
      expect(issues[2].message, contains('empty collection'));
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

  test('no_sql_string_interpolation: generic names need a database receiver, '
      'constants are safe', () {
    const source = r'''
const jsonPath = '$.meta.flags';
final class Paths {
  static const status = 'status';
}
Future<void> f(User user, String column, String input) async {
  user.raw('${column}_at');
  form.select('$column');
  raw('$column');
  query.whereRaw("json_extract(data, '${jsonPath}') = ?", [input]);
  query.whereRaw('${Paths.status} = ?' + ' AND 1 = 1', [input]);
  await DB.raw('count(${column})');
  await DB.table('users').select('$column');
  await User.query().where('a', 1).select('$column');
  await usersQuery.statement('DROP TABLE ' + input);
  query.whereRaw("json_extract(data, '${jsonPath}') = $input");
}
''';
    final issues = lintSource(source, 'lib/app/repo.dart');
    expect(rulesOf(issues).toSet(), {'no_sql_string_interpolation'});
    expect(issues.map((i) => i.line), [11, 12, 13, 14, 15]);
  });

  test(
    'unawaited_in_db_transaction flags queries that outlive the transaction',
    () {
      const source = '''
Future<void> f(User user, Map<String, int> totals) async {
  await DB.transaction(() async {
    await user.save();
    user.save();
    DB.table('logs').insert({'a': 1});
    unawaited(Post.query().where('id', 1).delete());
    order.save().ignore();
    for (final id in ids) {
      Tag.query().whereKey(id).update({'n': 1});
    }
    totals.update('a', (v) => v + 1);
    items.first;
    final pending = user.save();
    await pending;
    db.afterCommit(() => Mail.query().create({}));
    await DB.transaction(() async {
      user.touch();
    });
    return post.update({'title': 't'});
  });
  user.save(); // outside: not this rule's business
}
''';
      final issues = lintSource(source, 'lib/app/services/orders.dart');
      expect(rulesOf(issues).toSet(), {'unawaited_in_db_transaction'});
      expect(issues.map((i) => i.line), [4, 5, 6, 7, 9, 17]);
      expect(issues.first.message, contains('Add `await`'));
      expect(lintSource(source, 'lib/src/internal.dart'), isEmpty);
    },
  );

  test('invalid_validation_rule checks names and arguments', () {
    const source = '''
void routes(Router r) {
  r.post('/users', create).rules({
    'email': 'required|emial|max:255',
    'name': 'required|string|max',
    'age': ['nullable', 'integer', 'between:18'],
    'code': 'size:abc',
    'ok': 'required|string|max:255|in:a,b|unique:users,email',
    'terms': 'accepted|declined|accepted_if:a,b|declined_if:a,b',
    'dynamic': 'required|\$rule',
  });
}

final class StoreUser extends FormRequest {
  @override
  Map<String, Object> rules(Request request) => {'title': 'requird'};
}

Future<void> f(Request request, Map<String, Object?> data) async {
  await request.validate({'q': 'digits_between:1,x'});
  Validator(data, {'z': 'required'}); // daravel-lint-ignore: none
  Validator(data, {'z': 'nope'});
}
''';
    final issues = lintSource(source, 'lib/app/http/routes.dart');
    expect(rulesOf(issues).toSet(), {'invalid_validation_rule'});
    expect(issues.map((i) => i.line), [3, 4, 5, 6, 15, 19, 21]);
    expect(
      issues[0].message,
      'Unknown validation rule "emial" in '
      '"required|emial|max:255".',
    );
    expect(issues[1].message, contains('"max" needs 1 argument ("max:...")'));
    expect(issues[2].message, contains('"between" needs 2 arguments'));
    expect(issues[3].message, contains('expects a number, got "abc"'));
    expect(lintSource(source, 'lib/src/x.dart'), isEmpty);
  });

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
  test('seeders called by a registered seeder are registered', () async {
    final root = await Directory.systemTemp.createTemp('daravel_lints_');
    addTearDown(() => root.delete(recursive: true));
    void write(String path, String content) {
      final file = File(p.join(root.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    write(
      'bootstrap/seeders.dart',
      "import '../database/seeders/database_seeder.dart';\n",
    );
    write(
      'database/seeders/database_seeder.dart',
      "import 'candidate_seeder.dart';\nclass DatabaseSeeder {}\n",
    );
    // Reached through candidate_seeder.dart, two levels down.
    write(
      'database/seeders/candidate_seeder.dart',
      "import './question_seeder.dart';\nclass CandidateSeeder {}\n",
    );
    write('database/seeders/question_seeder.dart', 'class QuestionSeeder {}\n');
    write('database/seeders/orphan_seeder.dart', 'class OrphanSeeder {}\n');
    // A job imported by a registered job still needs its own definition.
    write(
      'bootstrap/jobs.dart',
      "import 'package:demo/app/jobs/send_mail.dart';\n",
    );
    write(
      'lib/app/jobs/send_mail.dart',
      "import 'retry_mail.dart';\nclass SendMail {}\n",
    );
    write('lib/app/jobs/retry_mail.dart', 'class RetryMail {}\n');

    expect(checkRegistries(root.path).map((i) => i.path).toList()..sort(), [
      'database/seeders/orphan_seeder.dart',
      'lib/app/jobs/retry_mail.dart',
    ]);
  });
  test('models are checked only once bootstrap/models.dart exists', () async {
    final root = await Directory.systemTemp.createTemp('daravel_lints_');
    addTearDown(() => root.delete(recursive: true));
    void write(String path, String content) {
      final file = File(p.join(root.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    write('lib/app/models/user.dart', 'class User {}\n');
    write('lib/app/models/post.dart', 'class Post {}\n');
    expect(checkRegistries(root.path), isEmpty, reason: 'no registry yet');

    write(
      'bootstrap/models.dart',
      "import 'package:demo/app/models/user.dart';\n",
    );
    final issues = checkRegistries(root.path);
    expect(issues.map((i) => i.path), ['lib/app/models/post.dart']);
    expect(issues.single.message, contains('bootstrap/models.dart'));
  });
  test('invalid_timezone checks scheduler zone names', () {
    const source = '''
void consoleRoutes(Schedule schedule) {
  schedule.command('a').daily().timezone('Asia/Jakarta');
  schedule.command('b').daily().timezone('UTC');
  schedule.command('c').daily().timezone('asia/jakarta');
  schedule.command('d').daily().timezone('Mars/Base');
  schedule.command('e').daily().timezone(const Duration(hours: 7));
  schedule.command('f').daily().timezone(zone);
}
''';
    final issues = lintSource(source, 'routes/console.dart');
    expect(issues.map((i) => i.rule).toSet(), {'invalid_timezone'});
    expect(issues.map((i) => i.line), [4, 5]);
    expect(issues[0].message, contains('did you mean "Asia/Jakarta"?'));
    expect(issues[1].message, contains('Unknown time zone "Mars/Base"'));
    expect(lintSource(source, 'lib/src/x.dart'), isEmpty);
  });

  group('no_inline_js_interpolation', () {
    const rule = [NoInlineJsInterpolation()];

    test('flags a Dart value inside an on* attribute, at the value', () {
      const source = r'''
String card(String id, String name) =>
    '<button onclick="join(\'$id\', \'${name}\')">Join</button>';
String image(String src) => "<img src=x onerror='load($src)'>";
String link(String id) => '<a href=# onclick=go($id)>x</a>';
''';
      final issues = lintSource(source, 'lib/resources/views/card.dart');
      expect(rulesOf(issues), List.filled(3, 'no_inline_js_interpolation'));
      final lines = source.split('\n');
      expect([for (final i in issues) i.line], [2, 3, 4]);
      // The column points at the first interpolation, not the literal.
      expect(issues[0].column, lines[1].indexOf(r'$id') + 1);
      expect(issues[1].column, lines[2].indexOf(r'$src') + 1);
      expect(issues[0].message, contains('addEventListener'));
    });

    test('flags a JavaScript template value in a page script', () {
      const source = r'''
String page() => """
<script>
  card.innerHTML = `
    <div class="m-title">\${escapeHtml(m.name)}</div>
    <button onclick="handleJoinMeeting('\${meetingId}', '\${m.name}')">
    <button onclick="openModal()">Edit</button>
    <button onclick="handleDeleteMeeting('\${meetingId}')">
  `;
</script>
""";
''';
      final issues = lintSource(source, 'lib/resources/views/page.dart');
      // One finding per attribute, each in the one long literal.
      expect(rulesOf(issues), List.filled(2, 'no_inline_js_interpolation'));
      expect([for (final i in issues) i.line], [5, 7]);
      expect(
        issues.first.column,
        source.split('\n')[4].indexOf(r'\${meetingId}') + 1,
      );
    });

    test('leaves handlers without values and values outside them', () {
      const source = r'''
String a(String label, String id, String t) =>
    '<button onclick="openModal()" title="$t">${label}</button>'
    '<button data-id="$id" class="join">Join</button>'
    '<p>Depends on: $label</p>'
    '<script>element.onclick = () => go(${id});</script>';
String b() => r'<button onclick="go()">${notDart}</button>';
''';
      expect(lintSource(source, 'lib/app/a.dart', rules: rule), isEmpty);
    });

    test('is silenced by an ignore comment and skips lib/src', () {
      const source = r'''
String card(String json) =>
    // daravel-lint-ignore: no_inline_js_interpolation
    '<button onclick="join($json)">Join</button>';
String other(String id) => '<a onclick="go($id)">x</a>';
''';
      final issues = lintSource(source, 'lib/app/a.dart', rules: rule);
      expect([for (final i in issues) i.line], [4]);
      expect(lintSource(source, 'lib/src/a.dart', rules: rule), isEmpty);
    });

    test('decodes escapes before it looks for the attribute', () {
      // \x6f\x6e is "on" and \x22 a double quote in the Dart value.
      const source = r'''
String a(String id) => '<b \x6f\x6eclick=\x22go($id)\x22>x</b>';
''';
      final issues = lintSource(source, 'lib/app/a.dart', rules: rule);
      expect(issues.single.column, source.indexOf(r'$id') + 1);
    });
  });

  group('prefer_sql_identifier', () {
    const rule = [PreferSqlIdentifier()];

    test('is opt-in: not in the default rules', () {
      expect(
        defaultRules.map((r) => r.name),
        isNot(contains('prefer_sql_identifier')),
      );
      const source = '''
void f(String sort) => DB.table('users').orderBy(sort);
''';
      expect(lintSource(source, 'lib/app/a.dart'), isEmpty);
      expect(
        rulesWith(['prefer_sql_identifier']).map((r) => r.name),
        contains('prefer_sql_identifier'),
      );
      expect(rulesWith(const []).length, defaultRules.length);
      expect(() => rulesWith(['nope']), throwsArgumentError);
    });

    test('reports computed column names', () {
      const source = r'''
Future<void> f(Request request, String sort, String col) async {
  await DB.table('users').orderBy(sort).get();
  await User.query().where(request.input('field'), 1).get();
  await DB.table('users').where('a', 1).whereIn('t_$col', [1]).get();
  await DB.table('users').select(['id', col]).get();
  final q = DB.table('users');
  q.orderByDesc(col);
  await q.pluck('name', col);
}
''';
      final issues = lintSource(source, 'lib/app/a.dart', rules: rule);
      expect([for (final i in issues) i.line], [2, 3, 4, 5, 7, 8]);
      expect(issues.first.rule, 'prefer_sql_identifier');
      expect(issues.first.message, contains('SqlIdentifier'));
    });

    test('accepts literals, constants, SqlIdentifier and whitelists', () {
      const source = r'''
const sortColumn = 'name';
Future<void> f(String input, SqlIdentifier typed, List<int> ids) async {
  final checked = SqlIdentifier(input);
  final maybe = SqlIdentifier.tryParse(input)!;
  final literal = 'email';
  await DB.table('users')
      .select(['id', 'users.name', checked])
      .where('email', 'a')
      .where((QueryBuilder q) => q.where('a', 1))
      .where({'a': 1})
      .whereIn(typed, ids)
      .orderBy(sortColumn)
      .orderBy(SqlIdentifier(input))
      .orderBy(maybe)
      .orderBy(literal)
      .orderBy(input == 'name' ? 'name' : 'id')
      .orderBy(switch (input) { 'age' => 'age', _ => 'id' })
      .orderBy(DB.raw('LENGTH(name)'))
      .get();
  ids.where((id) => id > 1);
  [input].where(isNotEmpty);
}
''';
      expect(lintSource(source, 'lib/app/a.dart', rules: rule), isEmpty);
    });

    test('is silenced by an ignore comment and skips lib/src', () {
      const source = '''
void f(String sort) {
  // daravel-lint-ignore: prefer_sql_identifier
  DB.table('users').orderBy(sort);
  DB.table('users').orderBy(sort);
}
''';
      final issues = lintSource(source, 'lib/app/a.dart', rules: rule);
      expect([for (final i in issues) i.line], [4]);
      expect(lintSource(source, 'lib/src/a.dart', rules: rule), isEmpty);
    });
  });

  test(
    'invalid_validation_rule: where conditions of unique/exists in pairs',
    () {
      const source = '''
void routes(Router r) {
  r.post('/users', create).rules({
    'a': 'unique:users,email,NULL,id,account_id,1',
    'b': 'exists:users,id,active,1',
    'c': 'unique:users,email,NULL,id|exists:users,id',
    'd': 'unique:users,email,NULL,id,account_id',
    'e': 'exists:users,id,active',
  });
}
''';
      final issues = lintSource(source, 'lib/app/http/routes.dart');
      expect(issues.map((i) => i.line), [6, 7]);
      expect(issues.first.message, contains('column,value pairs'));
    },
  );

  group('string_validation_rule', () {
    const rule = [StringValidationRule()];

    test('is opt-in', () {
      expect(
        defaultRules.map((r) => r.name),
        isNot(contains('string_validation_rule')),
      );
      expect(
        optionalRules.map((r) => r.name),
        contains('string_validation_rule'),
      );
    });

    test('reports a string a chain can replace, naming the chain', () {
      const source = r'''
Future<void> f(Request request) => request.validate({
  'email': 'required|email|max:255',
  'tags': ['array', Rules.distinct()],
  'slug': 'regex:/^[a-z]+$/',
});
''';
      final issues = lintSource(source, 'lib/app/a.dart', rules: rule);
      expect([for (final i in issues) i.line], [2, 3]);
      expect(
        issues.first.message,
        'Write the rules as a Rules chain: '
        'Rules.required().email().max(255)',
      );
      expect(issues.last.message, endsWith('Rules.array()'));
    });

    test('form request rules() and Validator maps too', () {
      const source = '''
final class StoreUser extends FormRequest {
  @override
  Map<String, Object> rules() => {'name': 'required|string'};
}
final v = Validator({}, {'age': 'integer|min:18'});
''';
      final issues = lintSource(source, 'lib/app/a.dart', rules: rule);
      expect([for (final i in issues) i.line], [3, 5]);
    });

    test('ruleChainSource', () {
      expect(
        ruleChainSource('nullable|unique:users,email'),
        "Rules.nullable().unique('users', 'email')",
      );
      expect(ruleChainSource('regex:/a/'), isNull);
      expect(ruleChainSource(''), isNull);
    });
  });
}
