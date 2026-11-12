import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// The pieces of typed foreign keys in `model:sync` (#330): which key gets
/// which type, the import it may need, and the way back out.
void main() {
  final session = ModelSource.parse('''
final class Session extends Model {
  static final ModelDefinition<Session> definition = ModelDefinition<Session>(
    table: 'sessions',
    factory: Session.new,
    fillable: ['assessment_id', 'graded_by', 'room_id'],
    casts: {'room_id': Cast.integer},
  );
}
''')!;

  TypedModel m(String className, String table, {String? idType}) => (
    className: className,
    table: table,
    primaryKey: 'id',
    idType: idType,
    file: '${table.substring(0, table.length - 1)}.dart',
  );

  ForeignKeyInfo key(
    List<String> columns,
    String table, [
    List<String> foreignColumns = const ['id'],
  ]) => ForeignKeyInfo(
    name: null,
    columns: columns,
    foreignSchema: null,
    foreignTable: table,
    foreignColumns: foreignColumns,
    onUpdate: null,
    onDelete: null,
  );

  group('foreignIdTypes', () {
    final byTable = {
      'assessments': [m('Assessment', 'assessments', idType: 'AssessmentId')],
      'sessions': [m('Session', 'sessions', idType: 'SessionId')],
      'users': [m('User', 'users')],
      'rooms': [m('Room', 'rooms', idType: 'RoomId')],
      'people': [
        m('Person', 'people', idType: 'PersonId'),
        m('Member', 'people', idType: 'MemberId'),
      ],
    };

    test('a one-column key to a typed model, its own table included', () {
      final found = foreignIdTypes(session, 'session.dart', [
        key(['assessment_id'], 'assessments'),
        // SQLite: REFERENCES assessments without a column = the key.
        key(['other_assessment_id'], 'assessments', const []),
        key(['parent_id'], 'sessions'),
      ], byTable);
      expect(found.types, {
        'assessment_id': 'AssessmentId',
        'other_assessment_id': 'AssessmentId',
        'parent_id': 'SessionId',
      });
      // Its own file is not imported.
      expect(found.files, {'assessment.dart': 'AssessmentId'});
      expect(found.notes, isEmpty);
    });

    test('left untyped: with a note, counted, or silently', () {
      final found = foreignIdTypes(session, 'session.dart', [
        key(['graded_by'], 'users'),
        key(['person_id'], 'people'),
        key(['audit_id'], 'audits'),
        key(['a', 'b'], 'assessments', const ['x', 'y']),
        key(['code'], 'assessments', const ['code']),
        key(['room_id'], 'rooms'),
      ], byTable);
      expect(found.types, isEmpty);
      expect(found.files, isEmpty);
      expect(found.notes, [
        '[graded_by]: User has no typed id; left untyped.',
        '[person_id]: table [people] has more than one model (Person, '
            'Member); left untyped.',
      ]);
      expect(found.unmodelled, 1);
    });
  });

  group('columnType and the write helpers', () {
    const assessment = ColumnInfo(
      name: 'assessment_id',
      type: 'INTEGER',
      nullable: false,
    );
    const graded = ColumnInfo(
      name: 'graded_by',
      type: 'INTEGER',
      nullable: true,
    );
    const room = ColumnInfo(name: 'room_id', type: 'INTEGER', nullable: false);
    const ids = {
      'assessment_id': 'AssessmentId',
      'graded_by': 'UserId',
      'room_id': 'RoomId',
    };

    test('nullable as the column is; the model cast wins', () {
      expect(columnType(session, assessment, foreignIds: ids), 'AssessmentId');
      expect(columnType(session, graded, foreignIds: ids), 'UserId?');
      expect(columnType(session, room, foreignIds: ids), 'int');
      expect(columnType(session, assessment), 'int');
    });

    test('cols, createWith and updateWith take the typed id', () {
      final plan = planAccessors(session, const [
        ColumnInfo(
          name: 'id',
          type: 'INTEGER',
          nullable: false,
          primary: true,
          autoIncrement: true,
        ),
        assessment,
        graded,
      ], foreignIds: ids);
      expect(
        plan.lines,
        containsAll([
          "    assessmentId: ModelColumn<Session, AssessmentId>('assessment_id'),",
          "  AssessmentId get assessmentId => getAttr('assessment_id');",
          "  set assessmentId(AssessmentId value) => "
              "setAttr('assessment_id', value);",
          '    required AssessmentId assessmentId,',
          '    Patch<UserId?> gradedBy = const Patch.absent(),',
        ]),
      );
    });
  });

  group('addModelImports', () {
    const ids = {'assessment.dart': 'AssessmentId'};

    test('one line, at its sorted place in a sorted block', () {
      const source = '''
import 'package:daravel/daravel.dart';

import 'room.dart';
import 'user.dart';

final class Session {}
''';
      final result = addModelImports(source, ids);
      expect(result.added, ['assessment.dart']);
      expect(result.source, '''
import 'package:daravel/daravel.dart';

import 'assessment.dart';
import 'room.dart';
import 'user.dart';

final class Session {}
''');
      // Once there, nothing more.
      expect(addModelImports(result.source, ids).added, isEmpty);
    });

    test(
      'after the last import when the block is not sorted, two in order',
      () {
        const source = '''
import 'user.dart';
import 'package:daravel/daravel.dart';

final class Session {}
''';
        final result = addModelImports(source, {'room.dart': 'RoomId', ...ids});
        expect(result.added, ['assessment.dart', 'room.dart']);
        expect(result.source, '''
import 'user.dart';
import 'package:daravel/daravel.dart';
import 'assessment.dart';
import 'room.dart';

final class Session {}
''');
      },
    );

    test('seen already: the file, its package uri, or the barrel', () {
      for (final import in [
        "import 'assessment.dart';",
        "import './assessment.dart';",
        "import 'package:app/app/models/assessment.dart';",
        "import 'assessment.dart' show Assessment, AssessmentId;",
        "import 'assessment.dart' hide Assessment;",
        "import 'models.dart';",
      ]) {
        final source = "$import\n\nfinal class Session {}\n";
        expect(
          addModelImports(
            source,
            ids,
            barrel: "export 'assessment.dart';\nexport 'session.dart';\n",
          ).source,
          source,
          reason: import,
        );
      }
    });

    test('not seen: a prefix, a show without it, a hide of it, a barrel '
        'that does not export it', () {
      for (final (import, barrel) in [
        ("import 'assessment.dart' as a;", null),
        ("import 'assessment.dart' show Assessment;", null),
        ("import 'assessment.dart' hide AssessmentId;", null),
        ("import 'models.dart';", "export 'session.dart';\n"),
      ]) {
        final result = addModelImports(
          "$import\n\nfinal class Session {}\n",
          ids,
          barrel: barrel,
        );
        expect(result.added, ['assessment.dart'], reason: import);
        // The user's import stays as written.
        expect(result.source, contains(import));
      }
    });

    test('a file without imports gets one at the top', () {
      expect(
        addModelImports('final class Session {}\n', ids).source,
        "import 'assessment.dart';\n\nfinal class Session {}\n",
      );
    });
  });

  test('untypeStatics: the generated finders take Object again', () {
    const source =
        '  // <dartisan:statics>\n'
        '  static Future<Lesson?> find(LessonId id) => query().find(id);\n'
        '  static Future<Lesson> findOrFail(LessonId id) =>\n'
        '      query().findOrFail(id);\n'
        '  static Future<Lesson?> byCode(LessonId id) => query().find(id);\n'
        '  // </dartisan:statics>\n'
        'Future<Lesson?> find(LessonId id) => Lesson.find(id);\n';
    final untyped = untypeStatics(source, 'LessonId');
    expect(untyped, contains('find(Object id) => query().find(id);'));
    expect(untyped, contains('findOrFail(Object id) =>'));
    expect(untyped, contains('byCode(LessonId id)'));
    expect(untyped, endsWith('find(LessonId id) => Lesson.find(id);\n'));
    expect(typeStatics(untyped, 'LessonId'), source);
  });
}
