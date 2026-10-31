import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Writer extends Model {
  static final ModelDefinition<Writer> definition = ModelDefinition<Writer>(
    table: 'writers',
    factory: Writer.new,
    timestamps: false,
    relations: {
      'books': () =>
          HasMany<Book>(() => Book.definition, foreignKey: 'writer_id'),
    },
  );
  @override
  ModelDefinition<Writer> get modelDefinition => definition;
}

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    timestamps: false,
    relations: {
      'writer': () =>
          BelongsTo<Writer>(() => Writer.definition, foreignKey: 'writer_id'),
      'pages': () =>
          HasMany<Page>(() => Page.definition, foreignKey: 'book_id'),
    },
  );
  @override
  ModelDefinition<Book> get modelDefinition => definition;
}

final class Note extends Model {
  static final ModelDefinition<Note> definition = ModelDefinition<Note>(
    table: 'notes',
    factory: Note.new,
    timestamps: false,
    relations: {
      'subject': () =>
          MorphTo(types: [() => Book.definition, () => Writer.definition]),
    },
  );
  @override
  ModelDefinition<Note> get modelDefinition => definition;
}

final class Page extends Model {
  static final ModelDefinition<Page> definition = ModelDefinition<Page>(
    table: 'pages',
    factory: Page.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Page> get modelDefinition => definition;
}

void main() {
  late Directory base;
  late Application app;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_autoload');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    await app.run(() async {
      for (final sql in const [
        'CREATE TABLE writers (id INTEGER PRIMARY KEY)',
        'CREATE TABLE books (id INTEGER PRIMARY KEY, writer_id INTEGER)',
        'CREATE TABLE pages (id INTEGER PRIMARY KEY, book_id INTEGER)',
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, subject_type TEXT, '
            'subject_id INTEGER)',
      ]) {
        await DB.statement(sql);
      }
      await DB.table('writers').insert([
        {'id': 1},
        {'id': 2},
      ]);
      await DB.table('books').insert([
        {'id': 1, 'writer_id': 1},
        {'id': 2, 'writer_id': 2},
        {'id': 3, 'writer_id': 1},
      ]);
      await DB.table('pages').insert([
        {'id': 1, 'book_id': 1},
        {'id': 2, 'book_id': 2},
      ]);
    });
  });

  tearDown(() async {
    Model.automaticallyEagerLoad = false;
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<int> counted(Future<void> Function() body) => app.run(() async {
    final (_, queries) = await DB.manager.captureQueries(body);
    return queries.length;
  });

  test('off by default: each load is a query', () async {
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      for (final book in books) {
        await book.load('writer');
      }
    });
    expect(count, 4);
  });

  test('a loop over one query loads once', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().orderBy('id').get();
      for (final book in books) {
        await book.load('writer');
      }
      expect(
        [for (final b in books) b.related<Writer>('writer').key],
        [1, 2, 1],
      );
    });
    expect(count, 2);
  });

  test('per query', () async {
    final count = await counted(() async {
      final books = await Book.definition
          .query()
          .withRelationshipAutoloading()
          .get();
      for (final book in books) {
        await book.load(['writer']);
      }
    });
    expect(count, 2);
  });

  test('Future.wait over the group is one query', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await Future.wait([for (final book in books) book.load('writer')]);
    });
    expect(count, 2);
  });

  test('it reaches down: children form a group of their own', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final writers = await Writer.definition.query().get();
      for (final writer in writers) {
        await writer.load('books');
        for (final book in writer.related<List<Book>>('books')) {
          await book.load('pages');
        }
      }
    });
    expect(count, 3, reason: 'writers, their books, the books\' pages');
  });

  test('a single result has no group', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final book = await Book.definition.query().find(1);
      await book!.load('writer');
    });
    expect(count, 2);
  });

  test('several names load together too', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      for (final book in books) {
        await book.load(['writer', 'pages']);
      }
    });
    expect(count, 3);
  });

  test('columns stay on the one model', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await books.first.load('writer:id');
      expect(books.first.relationLoaded('writer'), isTrue);
      expect(books[1].relationLoaded('writer'), isFalse);
    });
    expect(count, 2);
  });

  test('nesting stays on the one model', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await books.first.load('writer.books');
      expect(books[1].relationLoaded('writer'), isFalse);
    });
    expect(count, 3);
  });

  test('loading again reads again', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await books[0].load('writer');
      await books[1].load('writer'); // Served by the first.
      await books[0].load('writer'); // A refresh.
      await books[1].load('writer'); // A refresh too, now it has asked.
    });
    expect(count, 4);
  });

  test('a refresh sees the changed row', () async {
    Model.automaticallyEagerLoad = true;
    await app.run(() async {
      final books = await Book.definition.query().orderBy('id').get();
      await books[0].load('writer');
      await DB.table('books').where('id', 1).update({'writer_id': 2});
      final fresh = await Book.definition.query().orderBy('id').get();
      await fresh[0].load('writer');
      fresh[0].setAttr('writer_id', 1);
      await fresh[0].load('writer');
      expect(fresh[0].related<Writer>('writer').key, 1);
    });
  });

  test('a relation from with_ can still be refreshed', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().with_(['writer']).get();
      await books.first.load('writer');
    });
    expect(count, 3);
  });

  test('loadMissing loads together', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      for (final book in books) {
        await book.loadMissing(['writer', 'pages']);
      }
    });
    expect(count, 3);
  });

  test('after loadMissing, load refreshes', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await books[0].load('writer');
      await books[1].loadMissing(['writer']); // Has it: no query.
      await books[1].load('writer');
    });
    expect(count, 3);
  });

  test('a failed load leaves nothing behind', () async {
    Model.automaticallyEagerLoad = true;
    await app.run(() async {
      final books = await Book.definition.query().get();
      await expectLater(books.first.load('nothing'), throwsA(anything));
      await books.first.load('writer');
      expect(books.first.relationLoaded('writer'), isTrue);
    });
  });

  test('children of with_ form a group too', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final writers = await Writer.definition.query().with_(['books']).get();
      for (final writer in writers) {
        for (final book in writer.related<List<Book>>('books')) {
          await book.load('pages');
        }
      }
    });
    expect(count, 3);
  });

  test('withRelationshipAutoloading reaches the children of with_', () async {
    final count = await counted(() async {
      final writers = await Writer.definition
          .query()
          .with_(['books'])
          .withRelationshipAutoloading()
          .get();
      for (final writer in writers) {
        for (final book in writer.related<List<Book>>('books')) {
          await book.load('pages');
        }
      }
    });
    expect(count, 3);
  });

  test('a MorphTo keeps its types apart', () async {
    Model.automaticallyEagerLoad = true;
    await app.run(() async {
      await DB.table('notes').insert([
        {'id': 1, 'subject_type': r'App\Models\Book', 'subject_id': 1},
        {'id': 2, 'subject_type': r'App\Models\Book', 'subject_id': 2},
        {'id': 3, 'subject_type': r'App\Models\Writer', 'subject_id': 1},
        {'id': 4, 'subject_type': r'App\Models\Writer', 'subject_id': 2},
      ]);
    });
    final count = await counted(() async {
      final notes = await Note.definition.query().orderBy('id').get();
      for (final note in notes) {
        await note.load('subject');
      }
      for (final note in notes) {
        switch (note.related<Model>('subject')) {
          case final Book book:
            await book.load('writer');
            expect(book.relationLoaded('writer'), isTrue);
          case final Writer writer:
            await writer.load('books');
            expect(writer.relationLoaded('books'), isTrue);
        }
      }
    });
    expect(count, 5, reason: 'notes, books, writers, then one load per type');
  });

  test('parents sharing a child do not load it twice', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await Future.wait([for (final book in books) book.load('writer')]);
      await Future.wait([
        for (final book in books) book.related<Writer>('writer').load('books'),
      ]);
    });
    expect(count, 3, reason: 'books, writers, their books');
  });

  test('related stays strict: it never loads', () async {
    Model.automaticallyEagerLoad = true;
    await app.run(() async {
      final books = await Book.definition.query().get();
      expect(() => books.first.related<Writer>('writer'), throwsStateError);
    });
  });
}
