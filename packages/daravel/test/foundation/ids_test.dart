import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// What `dartisan model:sync --typed-ids` writes for a model.
extension type const NoteId(int value) implements int {
  static NoteId parse(String raw) {
    final id = int.parse(raw);
    if (id <= 0) {
      throw FormatException('Not a note id: $raw');
    }
    return NoteId(id);
  }
}

extension type const Slug(String value) implements String {}

final class Note extends Model {
  static final ModelDefinition<Note> definition = ModelDefinition<Note>(
    table: 'notes',
    factory: Note.new,
    timestamps: false,
    idType: IdType<NoteId>(
      parse: NoteId.parse,
      fromRow: (value) => NoteId(value! as int),
    ),
  );
  @override
  ModelDefinition<Note> get modelDefinition => definition;

  NoteId get id => getAttr('id');
}

Future<Note?> findNote(NoteId id) => Note.definition.query().find(id);

void main() {
  group('IdType', () {
    test('integer parses route text and database values', () {
      final type = IdType.integer(NoteId.new);
      expect(type.parse('42'), 42);
      expect(type.parse(' 7 '), 7);
      expect(type.fromRow(5), 5);
      expect(type.fromRow(5.0), 5);
      expect(type.fromRow('9'), 9);
      expect(() => type.parse('abc'), throwsFormatException);
      expect(() => type.fromRow(null), throwsFormatException);
      expect(() => type.fromRow(1.5), throwsFormatException);
    });

    test('string refuses an empty id', () {
      final type = IdType.string(Slug.new);
      expect(type.parse('01J9'), '01J9');
      expect(type.fromRow(12), '12');
      expect(() => type.parse(''), throwsFormatException);
      expect(() => type.fromRow(null), throwsFormatException);
    });

    test('TypedId is erased to its value', () {
      const id = TypedId<Note>(3);
      expect(id.asInt, 3);
      expect(id.asString, '3');
      expect(identical(id as Object, 3), isTrue);
      expect(() => const TypedId<Note>('x').asInt, throwsStateError);
    });

    test('ModelDefinition parses ids through idType, or not at all', () {
      expect(Note.definition.parseId('4'), 4);
      expect(() => Note.definition.parseId('0'), throwsFormatException);
      final plain = ModelDefinition<Note>(table: 'notes', factory: Note.new);
      expect(plain.parseId('4'), '4');
      expect(plain.idType, isNull);
      final note = Note.definition.hydrate({'id': 8});
      expect(Note.definition.idOf(note), 8);
      expect(note.id, 8);
    });

    test('IdParsers are keyed by parameter name', () {
      final ids = IdParsers()..register<NoteId>('note', NoteId.parse);
      expect(ids.isEmpty, isFalse);
      expect(ids.params, ['note']);
      expect(ids.parserFor('note')!('3'), 3);
      expect(ids.parserFor('user'), isNull);
    });
  });

  group('typed ids over HTTP', () {
    late Directory base;
    late Application app;
    late TestClient client;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_ids');
      app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withIds((ids) => ids.register<NoteId>('note', NoteId.parse))
          .withRouting(
            web: (router) {
              router.bindModel('bound', Note.definition);
              router.get(
                '/notes/{note}',
                (r) async => {
                  'id': (await findNote(r.param<NoteId>('note')))?.id,
                },
              );
              router.get(
                '/raw/{note}',
                (r) => {'raw': r.param<String>('note')},
              );
              router.get(
                '/explicit/{id}',
                (r) => {'id': r.param<NoteId>('id', parse: NoteId.parse)},
              );
              router.get('/plain/{id}', (r) => {'id': r.param<NoteId>('id')});
              router.get(
                '/bound/{bound}',
                (r) => {'id': r.binding<Note>('bound').id},
              );
            },
          )
          .create();
      await app.boot();
      await app.run(() async {
        await DB.statement('CREATE TABLE notes (id INTEGER PRIMARY KEY)');
        await DB.table('notes').insert({'id': 4});
      });
      client = TestClient(app);
    });

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    Future<int> status(String uri) async => (await client.get(uri)).status;

    test('a registered parser reads the parameter', () async {
      expect((await client.get('/notes/4')).jsonMap['id'], 4);
      expect(await status('/notes/0'), 404);
      expect(await status('/notes/abc'), 404);
    });

    test('a registered parser whose result is not T falls back', () async {
      expect((await client.get('/raw/4')).jsonMap['raw'], '4');
      expect(await status('/raw/0'), 404);
    });

    test(
      'an explicit parse wins, and no parser means the representation',
      () async {
        expect((await client.get('/explicit/4')).jsonMap['id'], 4);
        expect(await status('/explicit/-1'), 404);
        expect((await client.get('/plain/0')).jsonMap['id'], 0);
        expect(await status('/plain/x'), 404);
      },
    );

    test('route model binding parses through idType', () async {
      expect((await client.get('/bound/4')).jsonMap['id'], 4);
      expect(await status('/bound/0'), 404);
      expect(await status('/bound/abc'), 404);
    });
  });
}
