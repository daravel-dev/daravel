import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class CreateTables extends Migration {
  const CreateTables();

  @override
  String get name => '2026_01_01_000000_create_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('users', (t) {
      t.id();
      t.string('name');
    });
    await schema.create('assessments', (t) {
      t.id();
      t.string('title');
    });
    await schema.create('sessions', (t) {
      t.id();
      t.foreignId('assessment_id').constrained();
      t.foreignId('user_id').constrained();
      t.foreignId('parent_id').nullable().constrained('sessions');
      t.integer('score');
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('sessions');
    await schema.dropIfExists('assessments');
    await schema.dropIfExists('users');
  }
}

String _model(String className, String table) => renderStub(
  builtInStubs['model']!,
  {'class': className, 'table': table, 'softDeletes': ''},
);

/// `model:sync` and typed ids per model (#330): the opt-in lives in the
/// model's source, `--typed-ids` adds the models a run names, and a
/// foreign key to a model with a typed id gets that type.
void main() {
  late Directory root;
  File model(String file) =>
      File(p.join(root.path, 'lib', 'app', 'models', file));

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_typed_ids');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
    for (final (file, className, table) in [
      ('user.dart', 'User', 'users'),
      ('assessment.dart', 'Assessment', 'assessments'),
      ('session.dart', 'Session', 'sessions'),
    ]) {
      model(file)
        ..createSync(recursive: true)
        ..writeAsStringSync(_model(className, table));
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  Application createApp() => Application.configure(basePath: root.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': p.join(root.path, 'database.sqlite'),
      })
      .withMigrations(const [CreateTables()])
      .create();

  Future<(int, String)> run(List<String> args) async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(MigrateCommand(createApp))
      ..addCommand(ModelSyncCommand(createApp));
    // ignore: close_sinks (stdout of the zone, never opened)
    final out = _Capture();
    final code =
        await IOOverrides.runZoned<Future<int?>>(
          () => runner.run(args),
          getCurrentDirectory: () => root,
          stdout: () => out,
        ) ??
        0;
    return (code, out.buffer.toString());
  }

  test('opt in per model, keep it without the flag, type the foreign '
      'keys, opt out by deleting the region', () async {
    expect((await run(['migrate'])).$1, 0);

    // No model has a typed id: nothing is typed, nothing is noted.
    final (plain, plainOut) = await run(['model:sync', '--boot']);
    expect(plain, 0);
    expect(
      model('session.dart').readAsStringSync(),
      contains("int get assessmentId => getAttr('assessment_id');"),
    );
    expect(plainOut, isNot(contains('typed id')));

    // Two models opt in; User does not.
    final (typed, typedOut) = await run([
      'model:sync',
      '--boot',
      'Assessment',
      'Session',
      '--typed-ids',
    ]);
    expect(typed, 0);
    final session = model('session.dart').readAsStringSync();
    expect(
      session,
      allOf([
        contains("AssessmentId get assessmentId => getAttr('assessment_id');"),
        contains("SessionId? get parentId => getAttr('parent_id');"),
        contains("int get userId => getAttr('user_id');"),
        contains(
          "assessmentId: ModelColumn<Session, AssessmentId>('assessment_id')",
        ),
        contains('find(SessionId id)'),
        contains("import 'assessment.dart';"),
      ]),
    );
    expect(
      model('assessment.dart').readAsStringSync(),
      contains('find(AssessmentId id)'),
    );
    expect(model('user.dart').readAsStringSync(), contains('find(Object id)'));
    expect(
      typedOut,
      allOf([
        contains('Session: [user_id]: User has no typed id; left untyped.'),
        contains("Session: added import 'assessment.dart' to session.dart."),
      ]),
    );

    // The generated models compile, take the right id without a cast, and
    // refuse the id of another model.
    final errors = await _compileErrors(
      {
        for (final f in ['user.dart', 'assessment.dart', 'session.dart'])
          f: model(f).readAsStringSync(),
      },
      ok: '''
Future<void> ok(Session s) async {
  await Assessment.find(s.assessmentId);
  await Session.find(s.parentId!);
  Session.query().where(Session.cols.assessmentId.eq(s.assessmentId));
  Session.cols.assessmentId.inValues([s.assessmentId]);
  final int plain = s.assessmentId; // still an int where one is expected
  plain.isEven;
}
''',
      bad: [
        'Future<void> bad(Session s) async => Assessment.find(s.parentId!);',
        'void bad(Session s) => Session.cols.assessmentId.eq(s.parentId!);',
        'void bad(Session s) => Session.cols.parentId.inValues([s.assessmentId]);',
        'Future<void> bad(Session s) async => Assessment.find(s.userId);',
      ],
    );
    expect(errors, isEmpty);

    // A run without the flag keeps both: the opt-in is in the source.
    final before = {
      for (final f in ['user.dart', 'assessment.dart', 'session.dart'])
        f: model(f).readAsStringSync(),
    };
    final (again, againOut) = await run(['model:sync', '--boot']);
    expect(again, 0);
    expect(againOut, isNot(contains('written')));
    for (final MapEntry(key: f, value: text) in before.entries) {
      expect(model(f).readAsStringSync(), text, reason: f);
    }
    expect((await run(['model:sync', '--boot', '--check'])).$1, 0);

    // Opting out: delete the ids region of Assessment.
    final assessment = model('assessment.dart').readAsStringSync();
    final start = assessment.indexOf('// <dartisan:ids>');
    model('assessment.dart')
        .writeAsStringSync('${assessment.substring(0, start).trimRight()}\n');
    expect((await run(['model:sync', '--boot', '--check'])).$1, 1);
    expect((await run(['model:sync', '--boot'])).$1, 0);
    expect(
      model('assessment.dart').readAsStringSync(),
      allOf([contains('find(Object id)'), isNot(contains('AssessmentId'))]),
    );
    final after = model('session.dart').readAsStringSync();
    expect(
      after,
      contains("int get assessmentId => getAttr('assessment_id');"),
    );
    // Session stays opted in; the import it was given stays too.
    expect(after, contains("SessionId? get parentId"));
    expect(after, contains("import 'assessment.dart';"));
  });

  test('--dry-run and --check say they would add the import, and write '
      'nothing', () async {
    expect((await run(['migrate'])).$1, 0);
    expect(
      (await run(['model:sync', '--boot', 'Assessment', '--typed-ids'])).$1,
      0,
    );
    final session = model('session.dart').readAsStringSync();
    final (code, out) = await run([
      'model:sync',
      '--boot',
      'Session',
      '--typed-ids',
      '--check',
    ]);
    expect(code, 1);
    expect(out, contains("would add import 'assessment.dart'"));
    expect(model('session.dart').readAsStringSync(), session);
  });

  test('a named model that does not exist fails the run', () async {
    expect((await run(['migrate'])).$1, 0);
    final (code, out) = await run([
      'model:sync',
      '--boot',
      'Assessment',
      'Nope',
    ]);
    expect(code, 1);
    expect(out, contains('Model [nope] not found.'));
  });
}

/// What is wrong with [models] (file → source) as Dart, resolved against
/// this package's `daravel`: an error in a model or in [ok] (code that
/// uses them), or a snippet of [bad] that compiles although it passes the
/// id of another model. Empty when all is as it should be.
Future<List<String>> _compileErrors(
  Map<String, String> models, {
  required String ok,
  required List<String> bad,
}) async {
  // Inside the package, so its package config resolves package:daravel.
  final dir = Directory(
    p.join(
      Directory.current.path,
      '.dart_tool',
      'typed_ids_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    ),
  )..createSync(recursive: true);
  try {
    final files = <String, String>{
      ...models,
      'ok.dart': ok,
      for (final (i, snippet) in bad.indexed) 'bad_$i.dart': snippet,
    };
    const header = "import 'assessment.dart';\nimport 'session.dart';\n\n";
    for (final MapEntry(key: name, value: text) in files.entries) {
      File(
        p.join(dir.path, name),
      ).writeAsStringSync(models.containsKey(name) ? text : '$header$text\n');
    }
    final collection = AnalysisContextCollection(
      includedPaths: [p.normalize(dir.absolute.path)],
    );
    Future<List<Diagnostic>> errorsIn(String name) async {
      final path = p.normalize(p.join(dir.absolute.path, name));
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      return result is ErrorsResult
          ? [
              for (final d in result.diagnostics)
                if (d.severity == Severity.error) d,
            ]
          : [];
    }

    final problems = <String>[];
    for (final name in [...models.keys, 'ok.dart']) {
      for (final error in await errorsIn(name)) {
        problems.add('$name: ${error.message}');
      }
    }
    for (final (i, snippet) in bad.indexed) {
      if ((await errorsIn('bad_$i.dart')).isEmpty) {
        problems.add('compiles, but should not: $snippet');
      }
    }
    await collection.dispose();
    return problems;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

final class _Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
