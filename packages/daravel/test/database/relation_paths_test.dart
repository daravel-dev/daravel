import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

// Three models with the relation path extensions `dartisan model:sync`
// writes (dartisan_cli's typed_relations_sync_test checks the generator
// writes this text): an author has books, a book an author and pages, a
// page its book, so paths can go round.

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
}

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
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

  static const rels = (
    author: RelationToken<Book, Author>('author'),
    pages: RelationToken<Book, Page>('pages'),
  );
}

final class Page extends Model {
  static final ModelDefinition<Page> definition = ModelDefinition<Page>(
    table: 'pages',
    factory: Page.new,
    relations: {
      'book': () =>
          BelongsTo<Book>(() => Book.definition, foreignKey: 'book_id'),
    },
  );

  @override
  ModelDefinition<Page> get modelDefinition => Page.definition;

  static const cols = (
    id: ModelColumn<Page, int>('id'),
    bookId: ModelColumn<Page, int>('book_id'),
    number: ModelColumn<Page, int>('number'),
  );

  static const rels = (book: RelationToken<Page, Book>('book'));
}

/// The relations of [Author], after any relation path that ends at an
/// author (written by `dartisan model:sync`).
extension AuthorRelationPath<Root extends Model>
    on RelationToken<Root, Author> {
  /// The path so far, then `books`.
  RelationToken<Root, Book> get books => nested(Author.rels.books);
}

/// The relations of [Book], after any relation path that ends at a book
/// (written by `dartisan model:sync`).
extension BookRelationPath<Root extends Model> on RelationToken<Root, Book> {
  /// The path so far, then `author`.
  RelationToken<Root, Author> get author => nested(Book.rels.author);

  /// The path so far, then `pages`.
  RelationToken<Root, Page> get pages => nested(Book.rels.pages);
}

/// The relations of [Page], after any relation path that ends at a page
/// (written by `dartisan model:sync`).
extension PageRelationPath<Root extends Model> on RelationToken<Root, Page> {
  /// The path so far, then `book`.
  RelationToken<Root, Book> get book => nested(Page.rels.book);
}

/// Relation paths (Blueprint #155 Rev. 1): `Author.rels.books.pages` is the
/// string `books.pages`, so every query method sees what it always saw.
void main() {
  group('the path is the dotted string', () {
    test('2, 3 and 5 levels, going round', () {
      final RelationToken<Author, Page> two = Author.rels.books.pages;
      expect(two.name, 'books.pages');
      final RelationToken<Author, Book> three = Author.rels.books.pages.book;
      expect(three.name, 'books.pages.book');
      final RelationToken<Author, Page> five =
          Author.rels.books.author.books.pages.book.pages;
      expect(five.name, 'books.author.books.pages.book.pages');
      expect(
        Author.rels.books.author.books.pages.name,
        Author.rels.books
            .nested(Book.rels.author)
            .nested(Author.rels.books)
            .nested(Book.rels.pages)
            .name,
      );
    });

    test('only after a path takes the columns of its last model', () {
      expect(
        '${Author.rels.books.pages.only([Page.cols.id, Page.cols.number])}',
        'books.pages:id,number',
      );
    });
  });

  group('queries', () {
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
        'CREATE TABLE authors ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
            '"name" TEXT)',
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
        {'author_id': 2, 'title': 'Two'},
      ]);
      await db.table('pages').insert([
        {'book_id': 1, 'number': 1},
        {'book_id': 1, 'number': 2},
      ]);
    });

    tearDown(() => db.closeAll());

    ModelQuery<Author> authors() =>
        Author.definition.query(db: db).orderBy('id');

    test('whereHas, has and doesntHave give the SQL of the string', () async {
      for (final (path, string) in [
        (Author.rels.books.pages, 'books.pages'),
        (Author.rels.books.pages.book.author, 'books.pages.book.author'),
      ]) {
        expect(
          authors().whereHas(path).toSql(),
          authors().whereHas(string).toSql(),
        );
        expect(authors().has(path).toSql(), authors().has(string).toSql());
        expect(
          authors().doesntHave(path).toSql(),
          authors().doesntHave(string).toSql(),
        );
        expect(
          await authors().whereHas(path).pluck('name'),
          await authors().whereHas(string).pluck('name'),
        );
      }
      expect(await authors().whereHas(Author.rels.books.pages).pluck('name'), [
        'Ana',
      ]);
    });

    test('with_ and load load what the string loads', () async {
      final viaPath = await authors().with_([
        Author.rels.books.pages.book,
      ]).get();
      final viaString = await authors().with_(['books.pages.book']).get();
      List<Object?> loaded(ModelCollection<Author> all) => [
        for (final author in all)
          for (final book in author.related<ModelCollection<Book>>('books'))
            [
              book.relationLoaded('pages'),
              for (final page in book.related<ModelCollection<Page>>('pages'))
                page.relationLoaded('book'),
            ],
      ];
      expect(loaded(viaPath), loaded(viaString));
      expect(loaded(viaPath), [
        [true, true, true],
        [true],
      ]);

      final ana = (await authors().first())!;
      await ana.load([Author.rels.books.pages]);
      final book = ana.related<ModelCollection<Book>>('books').single;
      expect(book.relationLoaded('pages'), isTrue);
    });

    test('with_ of a path with only loads those columns', () async {
      final ana = (await authors().with_([
        Author.rels.books.pages.only([Page.cols.number]),
      ]).first())!;
      final book = ana.related<ModelCollection<Book>>('books').single;
      expect(
        book
            .related<ModelCollection<Page>>('pages')
            .map((p) => p.attributes.keys.toSet()),
        everyElement(containsAll(['number', 'book_id'])),
      );
    });
  });

  test('relationTokenMembers is every member RelationToken has', () {
    // An extension getter named like a member of the extension type is
    // shadowed by it without an error; model:sync skips those names, and
    // a new member of RelationToken has to be added to the set.
    final unit = parseString(
      content: File('lib/src/database/orm/typed_columns.dart')
          .readAsStringSync(),
    ).unit;
    final token = unit.declarations
        .whereType<ExtensionTypeDeclaration>()
        .singleWhere((d) => d.namePart.typeName.lexeme == 'RelationToken');
    final own = <String>{
      // The representation field (`name`).
      for (final parameter
          in (token.namePart as PrimaryConstructorDeclaration)
              .formalParameters
              .parameters)
        ?parameter.name?.lexeme,
      for (final member in token.body.members)
        if (member is MethodDeclaration && !member.isOperator)
          member.name.lexeme
        else if (member is FieldDeclaration)
          for (final variable in member.fields.variables) variable.name.lexeme,
    };
    // Object's members, which every extension type implementing Object
    // has (== is an operator, not a name).
    const object = {'hashCode', 'runtimeType', 'toString', 'noSuchMethod'};
    expect(relationTokenMembers, {...own, ...object});
  });
}
