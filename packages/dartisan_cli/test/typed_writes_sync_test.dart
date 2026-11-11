import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `model:sync` writes `createWith`, `makeWith`, `fillWith` and
/// `updateWith` from the fillable columns (W9.13, Review #151 R6).
void main() {
  const source = '''
import 'package:daravel/daravel.dart';

final class Member extends Model {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
    fillable: ['name', 'email', 'nickname', 'status', 'verified_at'],
    attributes: const {'status': 'draft'},
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const columns = [
    ColumnInfo(
      name: 'id',
      type: 'INTEGER',
      nullable: false,
      primary: true,
      autoIncrement: true,
    ),
    ColumnInfo(name: 'name', type: 'VARCHAR', nullable: false),
    ColumnInfo(name: 'email', type: 'VARCHAR', nullable: false),
    ColumnInfo(name: 'nickname', type: 'VARCHAR', nullable: true),
    ColumnInfo(
      name: 'status',
      type: 'VARCHAR',
      nullable: false,
      defaultValue: "'draft'",
    ),
    ColumnInfo(name: 'verified_at', type: 'TEXT', nullable: true),
    ColumnInfo(name: 'is_admin', type: 'INTEGER', nullable: false),
    ColumnInfo(name: 'created_at', type: 'TEXT', nullable: true),
  ];

  test('parameters follow fillable; required means no default', () {
    final model = ModelSource.parse(source)!;
    expect(model.fillable, [
      'name',
      'email',
      'nickname',
      'status',
      'verified_at',
    ]);
    expect(model.guarded, ['*']);
    final all = planAccessors(model, columns).lines;
    final lines = all.sublist(all.indexWhere((l) => l.contains('createWith')));
    expect(
      lines,
      containsAll([
        '  static Future<Member> createWith({',
        '    required String name,',
        '    required String email,',
        '    String? nickname,',
        '    String? status,',
        "    'name': name,",
        "    'nickname': ?nickname,",
        '  Future<bool> updateWith({',
        '    String? name,',
        '    Patch<String?> nickname = const Patch.absent(),',
        "    if (nickname.isPresent) 'nickname': nickname.value,",
        '  Member fillWith({',
        '  static Member makeWith({',
      ]),
    );
    // Not fillable, the key and timestamps: never parameters.
    for (final name in ['isAdmin', ' id,', 'createdAt']) {
      expect(lines.where((l) => l.contains(name) && l.contains('?')), isEmpty);
    }
  });

  test('guarded, not fillable, decides when fillable is empty', () {
    final model = ModelSource.parse(
      source.replaceFirst(
        "fillable: ['name', 'email', 'nickname', 'status', 'verified_at'],",
        "guarded: ['is_admin'],",
      ),
    )!;
    final all = planAccessors(model, columns).lines;
    final lines = all
        .sublist(all.indexWhere((l) => l.contains('createWith')))
        .join('\n');
    expect(lines, contains('required String name,'));
    expect(lines, isNot(contains('isAdmin')));
  });

  test('without a fillable column nothing is written, with one warning', () {
    final model = ModelSource.parse(
      source.replaceFirst(
        "fillable: ['name', 'email', 'nickname', 'status', 'verified_at'],",
        '',
      ),
    )!;
    final plan = planAccessors(model, columns);
    expect(plan.lines.where((l) => l.contains('With(')), isEmpty);
    expect(
      plan.warnings,
      contains(allOf(contains('Member: no fillable column'), contains("'*'"))),
    );
  });

  test('the synced model compiles; misuse does not', () async {
    final dir = Directory(
      p.normalize(p.absolute('.dart_tool/typed_api_writes')),
    );
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    final synced = syncModelSource(
      source,
      ModelSource.parse(source)!,
      columns,
    ).source!;
    final files = {
      'member.dart': synced,
      'ok.dart': '''
import 'package:daravel/daravel.dart';

import 'member.dart';

Future<void> ok(Member member) async {
  await Member.createWith(name: 'Ana', email: 'ana@example.com');
  Member.makeWith(name: 'B', email: 'b@example.com', nickname: 'bee');
  member.fillWith(nickname: const Patch(null));
  await member.updateWith(name: 'C', verifiedAt: const Patch('2026-01-01'));
}
''',
      'missing_required.dart': '''
import 'member.dart';

Future<void> f() async {
  await Member.createWith(name: 'Ana');
}
''',
      'patch_needed.dart': '''
import 'member.dart';

Future<void> f(Member member) async {
  await member.updateWith(nickname: null);
}
''',
      'not_fillable.dart': '''
import 'member.dart';

Future<void> f() async {
  await Member.createWith(name: 'A', email: 'a@x', isAdmin: 1);
}
''',
    };
    for (final MapEntry(:key, :value) in files.entries) {
      File(p.join(dir.path, key)).writeAsStringSync(value);
    }
    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    Future<List<String>> codes(String name) async {
      final path = p.join(dir.path, name);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      return [
        if (result is ErrorsResult)
          for (final d in result.diagnostics) d.diagnosticCode.lowerCaseName,
      ];
    }

    expect(await codes('member.dart'), isEmpty, reason: synced);
    expect(await codes('ok.dart'), isEmpty);
    expect(await codes('missing_required.dart'), ['missing_required_argument']);
    expect(await codes('patch_needed.dart'), ['argument_type_not_assignable']);
    expect(await codes('not_fillable.dart'), ['undefined_named_parameter']);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
