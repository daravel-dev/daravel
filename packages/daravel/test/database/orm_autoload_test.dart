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

  test('constraints and nesting stay on the one model', () async {
    Model.automaticallyEagerLoad = true;
    final count = await counted(() async {
      final books = await Book.definition.query().get();
      await books.first.load(['writer', 'pages']);
    });
    expect(count, 3);
  });

  test('related stays strict: it never loads', () async {
    Model.automaticallyEagerLoad = true;
    await app.run(() async {
      final books = await Book.definition.query().get();
      expect(() => books.first.related<Writer>('writer'), throwsStateError);
    });
  });
}
