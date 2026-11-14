import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:dartisan_cli/src/source_text.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every string value of [source]'s literals; fails when it does not parse.
Set<String> literals(String source, {String reason = ''}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  expect(result.errors, isEmpty, reason: '$reason\n$source');
  final values = <String>{};
  result.unit.accept(_Literals(values));
  return values;
}

final class _Literals extends RecursiveAstVisitor<void> {
  _Literals(this.values);

  final Set<String> values;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    values.add(node.value);
    super.visitSimpleStringLiteral(node);
  }
}

/// What generators write from outside values (column names, `.env` keys,
/// options) parses, and each value comes back as itself.
void main() {
  const tricky = [
    "evil'col\$x",
    r'amount$usd',
    r'back\slash',
    'line1\nline2',
    'cr\rlf',
    'tab\there',
    'nul\u0000bell\u0007',
    r"'''",
    r'${1+1}',
  ];

  test('dartString: each value round-trips through a Dart literal', () {
    final source = [
      for (final (i, value) in tricky.indexed)
        'const v$i = ${dartString(value)};',
    ].join('\n');
    expect(literals(source), tricky.toSet());
  });

  test('commentText keeps a comment on one line', () {
    final source =
        '/// ${commentText('a\r\n}\nvoid f() {}\n  b')}\nvoid g() {}';
    final unit = parseString(content: source).unit;
    expect(unit.declarations, hasLength(1));
    expect(commentText('a\r\n}\nvoid f() {}\n  b'), 'a } void f() {} b');
  });

  test('model:sync: column names with quotes, \$, backslashes and line '
      'breaks parse and keep their names', () {
    final columns = [
      const ColumnInfo(
        name: 'id',
        type: 'INTEGER',
        nullable: false,
        primary: true,
        autoIncrement: true,
      ),
      for (final name in tricky)
        ColumnInfo(name: name, type: 'VARCHAR', nullable: true),
    ];
    final made = renderStub(builtInStubs['model']!, {
      'class': 'Item',
      'table': 'items',
      'softDeletes': '',
    });
    final synced = syncModelSource(made, ModelSource.parse(made)!, columns);
    expect(literals(synced.source!), containsAll(tricky));
  });

  test('request:sync: a key with an escaped quote stays one literal, and a '
      'key over two lines is not read', () {
    const source = r"""
final class SaveRequest extends FormRequest<SaveInput> {
  static const quoted = Field<String>('it\'s');
  static const money = Field<int>('price\$usd');
  static const broken = Field<String>('line1
line2');
}
""";
    final request = RequestSource.parse(source)!;
    expect(request.fields.map((f) => f.name), ['quoted', 'money']);
    final region = inputRegion(request);
    expect(literals(region), containsAll(["it's", r'price$usd']));
  });

  group('env:obfuscate', () {
    test('keys with no letters, reserved words and clashing names give '
        'valid, distinct getters; keys are escaped in toMap', () {
      final out = EnvObfuscateCommand().renderObfuscatedEnv({
        '_': 'a',
        '__': 'b',
        'IF': 'c',
        'NEW': 'd',
        'FOO_BAR': 'e',
        'FOO__BAR': 'f',
        "FOO\$BAR'BAZ": 'g',
        'TO_MAP': 'h',
      });
      final values = literals(out);
      expect(values, containsAll(['_', '__', 'IF', "FOO\$BAR'BAZ"]));
      final getters = <String>[];
      parseString(content: out).unit.accept(_Getters(getters));
      expect(getters.toSet(), hasLength(getters.length));
      expect(getters, containsAll(['value', 'value2', 'ifValue', 'fooBar2']));
    });

    test('--class must be a class name', () async {
      final root = Directory.systemTemp.createTempSync('obfuscate_class');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, '.env')).writeAsStringSync('A=1\n');
      for (final name in ['Bad Name', 'X\nvoid f() {}', 'class', '1X']) {
        final runner = CommandRunner<int>('t', 't')
          ..addCommand(EnvObfuscateCommand(root: root.path));
        await expectLater(
          // `--class value`: `--class=` cannot carry a line break.
          runner.run(['env:obfuscate', '--class', name]),
          throwsA(isA<UsageException>()),
          reason: name,
        );
      }
    });
  });

  group('make:*', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('make_escapes');
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
      Directory(p.join(root.path, 'bootstrap')).createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<int> run(List<String> args) => IOOverrides.runZoned(
      () => DartisanRunner(
        () => Application.configure(basePath: root.path).create(),
      ).execute(args),
      getCurrentDirectory: () => root,
      stdout: () => _Silent(),
    );

    String only(String dir) =>
        Directory(p.join(root.path, dir))
            .listSync(recursive: true)
            .whereType<File>()
            .single
            .readAsStringSync();

    test('--create, --table and --command values stay strings', () async {
      expect(
        // `--create value`: `--create=` cannot carry a line break.
        await run([
          'make:migration',
          'create_things',
          '--create',
          "th'ings\nx",
        ]),
        0,
      );
      expect(literals(only('database/migrations')), contains("th'ings\nx"));
      expect(await run(['make:model', 'Thing', r'--table=t$x']), 0);
      expect(literals(only('lib/app/models')), contains(r't$x'));
      expect(
        await run([
          'make:command',
          'Sync',
          '--command',
          "sync:it'\nvoid f() {}",
        ]),
        0,
      );
      expect(
        literals(only('lib/app/console')),
        contains("sync:it'\nvoid f() {}"),
      );
    });
  });
}

final class _Silent implements Stdout {
  @override
  void write(Object? object) {}

  @override
  void writeln([Object? object = '']) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Getters extends RecursiveAstVisitor<void> {
  _Getters(this.names);

  final List<String> names;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter) {
      names.add(node.name.lexeme);
    }
    super.visitMethodDeclaration(node);
  }
}
