import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:dartisan_cli/src/stubs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `model:sync` writes `static const cols = (...)` (W9.1): one name rule
/// for the accessors and the `cols` fields, so `user.x` and `User.cols.x`
/// are always the same column, and a file that compiles whatever the
/// column names are.
void main() {
  const columns = [
    ColumnInfo(
      name: 'id',
      type: 'INTEGER',
      nullable: false,
      primary: true,
      autoIncrement: true,
    ),
    ColumnInfo(name: 'email', type: 'VARCHAR', nullable: false),
    ColumnInfo(name: 'hash_code', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: '_lft', type: 'INTEGER', nullable: true),
    ColumnInfo(name: 'lft', type: 'INTEGER', nullable: true),
    ColumnInfo(name: 'to_string', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: '1st_name', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: 'key', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: 'class', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: 'remember_token', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: 'created_at', type: 'TIMESTAMP', nullable: true),
  ];

  test('one name rule for accessors and cols fields', () {
    final names = {
      for (final n in columnNames(columns)) n.column.name: (n.getter, n.field),
    };
    expect(names, {
      'id': ('id', 'id'),
      'email': ('email', 'email'),
      'hash_code': (null, 'hashCodeColumn'),
      // The first column with a name keeps it; the second gets no accessor.
      '_lft': ('lft', 'lft'),
      'lft': (null, 'lftColumn'),
      'to_string': (null, 'toStringColumn'),
      '1st_name': (null, 'c1stName'),
      'key': (null, 'key'),
      'class': (null, 'classColumn'),
      'remember_token': (null, 'rememberToken'),
      'created_at': ('createdAt', 'createdAt'),
    });
    // Same every time.
    expect(
      columnNames(columns).map((n) => n.field),
      columnNames(columns).map((n) => n.field),
    );
  });

  test('a skipped column is reported with its cols field', () {
    final made = renderStub(builtInStubs['model']!, {
      'class': 'Node',
      'table': 'nodes',
      'softDeletes': '',
    });
    final plan = planAccessors(ModelSource.parse(made)!, columns);
    expect(
      plan.warnings,
      contains(contains('[lft]: accessor `lft` is already the accessor')),
    );
    expect(plan.warnings, contains(contains('Node.cols.c1stName')));
  });

  test('the synced model compiles, and its tokens type the columns', () async {
    final made = renderStub(builtInStubs['model']!, {
      'class': 'Node',
      'table': 'nodes',
      'softDeletes': '',
    });
    final synced = syncModelSource(made, ModelSource.parse(made)!, columns);
    final dir = Directory(p.normalize(p.absolute('.dart_tool/typed_api_sync')));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'node.dart')).writeAsStringSync(synced.source!);
    File(p.join(dir.path, 'use.dart')).writeAsStringSync('''
import 'package:daravel/daravel.dart';

import 'node.dart';

Future<void> use(Node node) async {
  final int? lft = node.lft;
  final ModelColumn<Node, int?> sameColumn = Node.cols.lft;
  final ModelColumn<Node, int?> other = Node.cols.lftColumn;
  final ModelColumn<Node, String?> hashCodeColumn = Node.cols.hashCodeColumn;
  await Node.query().orderByDesc(Node.cols.id).pluck(Node.cols.email);
  print([lft, sameColumn, other, hashCodeColumn, Node.cols.c1stName]);
}
''');
    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    final found = <String>[];
    for (final name in ['node.dart', 'use.dart']) {
      final path = p.join(dir.path, name);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      if (result is ErrorsResult) {
        for (final d in result.diagnostics) {
          found.add(
            '$name:${result.lineInfo.getLocation(d.offset).lineNumber} '
            '${d.diagnosticCode.lowerCaseName}: ${d.message}',
          );
        }
      } else {
        found.add('$name: not analyzed');
      }
    }
    expect(found, isEmpty, reason: synced.source);
    expect(
      synced.source,
      contains("    lft: ModelColumn<Node, int?>('_lft'),"),
    );
    expect(
      synced.source,
      contains("    lftColumn: ModelColumn<Node, int?>('lft'),"),
    );
    expect(synced.source, contains("int? get lft => getAttr('_lft');"));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
