import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    relations: {
      'books': () =>
          HasMany<Book>(() => Book.definition, foreignKey: 'author_id'),
    },
  );

  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;

  static const rels = (books: RelationToken<Author, Book>('books'));

  ModelCollection<Book> get books => related('books');
}

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    relations: {
      'pages': () =>
          HasMany<Page>(() => Page.definition, foreignKey: 'book_id'),
    },
  );

  @override
  ModelDefinition<Book> get modelDefinition => Book.definition;

  static const cols = (
    id: ModelColumn<Book, int>('id'),
    authorId: ModelColumn<Book, int>('author_id'),
    title: ModelColumn<Book, String>('title'),
  );

  static const rels = (pages: RelationToken<Book, Page>('pages'));
}

final class Page extends Model {
  static final ModelDefinition<Page> definition = ModelDefinition<Page>(
    table: 'pages',
    factory: Page.new,
  );

  @override
  ModelDefinition<Page> get modelDefinition => Page.definition;
}

/// Typed relations (W9.3): a `RelationToken` is the relation's name at run
/// time, so eager loading, counts and existence filters see the string
/// they always saw; `nested` and `only` build Laravel's dotted and column
/// forms.
void main() {
  late DatabaseManager db;

  setUp(() async {
    db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    for (final sql in [
      'CREATE TABLE authors ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT)',
      'CREATE TABLE books ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
          '"author_id" INTEGER, "title" TEXT)',
      'CREATE TABLE pages ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
          '"book_id" INTEGER, "number" INTEGER)',
    ]) {
      await db.statement(sql);
    }
    await db.table('authors').insert([
      {'name': 'Ana'},
      {'name': 'Budi'},
    ]);
    await db.table('books').insert([
      {'author_id': 1, 'title': 'One'},
      {'author_id': 1, 'title': 'Two'},
    ]);
    await db.table('pages').insert([
      {'book_id': 1, 'number': 1},
      {'book_id': 1, 'number': 2},
    ]);
  });

  tearDown(() => db.closeAll());

  test('nested and only give the dotted and column forms', () {
    expect(Author.rels.books.name, 'books');
    expect(Author.rels.books.nested(Book.rels.pages).name, 'books.pages');
    expect(
      '${Author.rels.books.only([Book.cols.id, Book.cols.authorId, Book.cols.title])}',
      'books:id,author_id,title',
    );
  });

  test('with_, nested and only load what the strings load', () async {
    final authors = await Author.definition
        .query(db: db)
        .with_([
          Author.rels.books.only([Book.cols.id, Book.cols.authorId]),
        ])
        .orderBy('id')
        .get();
    expect(authors.first.books.map((b) => b.attributes.keys.toSet()), [
      {'id', 'author_id'},
      {'id', 'author_id'},
    ]);
    final deep = await Author.definition
        .query(db: db)
        .with_([Author.rels.books.nested(Book.rels.pages)])
        .orderBy('id')
        .first();
    expect(deep!.books.first.relationLoaded('pages'), isTrue);
  });

  test('whereHas, doesntHave and withCount take tokens', () async {
    final withBooks = await Author.definition
        .query(db: db)
        .whereHas(Author.rels.books)
        .pluck('name');
    expect(withBooks, ['Ana']);
    final without = await Author.definition
        .query(db: db)
        .doesntHave(Author.rels.books)
        .pluck('name');
    expect(without, ['Budi']);
    final nested = await Author.definition
        .query(db: db)
        .whereHas(Author.rels.books.nested(Book.rels.pages))
        .pluck('name');
    expect(nested, ['Ana']);
    final counted = await Author.definition
        .query(db: db)
        .withCount(Author.rels.books)
        .orderBy('id')
        .get();
    expect(counted.map((a) => a.getAttr<Object?>('books_count')), [2, 0]);
  });

  test('load on a model and a collection takes tokens', () async {
    final ana = (await Author.definition.query(db: db).orderBy('id').first())!;
    await ana.load([Author.rels.books]);
    expect(ana.books, hasLength(2));
  });

  test(
    'only() without the matching key still loads (the key is added)',
    () async {
      final ana = await Author.definition
          .query(db: db)
          .with_([
            Author.rels.books.only([Book.cols.title]),
          ])
          .orderBy('id')
          .first();
      expect(ana!.books.map((b) => b.getAttr<String>('title')), ['One', 'Two']);
    },
  );

  test('a relation getter before loading names the ways to load it', () async {
    final ana = (await Author.definition.query(db: db).orderBy('id').first())!;
    expect(
      () => ana.books,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('loadBooks()'),
            contains("load(['books'])"),
            contains('with_([Author.rels.books])'),
          ),
        ),
      ),
    );
  });

  test('a relation argument that is not a name is refused', () {
    expect(
      () => Author.definition.query(db: db).whereHas(42),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'relation')),
    );
  });
}
