import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `model:sync` writes `static const rels = (...)`, a typed getter and a
/// loader per relation of the model's `relations:` map (W9.3).
void main() {
  const writer = '''
import 'package:daravel/daravel.dart';

import 'book.dart';

final class Writer extends Model {
  static final ModelDefinition<Writer> definition = ModelDefinition<Writer>(
    table: 'writers',
    factory: Writer.new,
    relations: {
      'books': () => HasMany<Book>(() => Book.definition, foreignKey: 'writer_id'),
      'latestBook': () =>
          HasOne<Book>(() => Book.definition, foreignKey: 'writer_id'),
      'missing': () => HasMany<Book>(() => Book.definition, foreignKey: 'x'),
      'email': () => HasOne<Book>(() => Book.definition, foreignKey: 'y'),
      'key': () => HasOne<Book>(() => Book.definition, foreignKey: 'z'),
    },
  );

  @override
  ModelDefinition<Writer> get modelDefinition => Writer.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const book = '''
import 'package:daravel/daravel.dart';

import 'writer.dart';

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    relations: {
      'writer': () => BelongsTo<Writer>(() => Writer.definition, foreignKey: 'writer_id'),
      'owner': () => MorphTo(),
    },
  );

  @override
  ModelDefinition<Book> get modelDefinition => Book.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const writerColumns = [
    ColumnInfo(name: 'id', type: 'INTEGER', nullable: false, primary: true),
    ColumnInfo(name: 'email', type: 'VARCHAR', nullable: false),
  ];
  const bookColumns = [
    ColumnInfo(name: 'id', type: 'INTEGER', nullable: false, primary: true),
    ColumnInfo(name: 'writer_id', type: 'INTEGER', nullable: false),
  ];

  const shelf = '''
import 'package:daravel/daravel.dart';

import 'book.dart';

final class Shelf extends Model {
  static final ModelDefinition<Shelf> definition = ModelDefinition<Shelf>(
    table: 'shelves',
    factory: Shelf.new,
    relations: {
      'cols': () => HasMany<Book>(() => Book.definition, foreignKey: 'shelf_id'),
      'posts': () => HasMany<Book>(() => Book.definition, foreignKey: 'a'),
      'pages':
          () =>
              HasMany<Book>(() => Book.definition, foreignKey: 'b'),
    },
  );

  @override
  ModelDefinition<Shelf> get modelDefinition => Shelf.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const shelfColumns = [
    ColumnInfo(name: 'id', type: 'INTEGER', nullable: false, primary: true),
    ColumnInfo(name: 'cols', type: 'VARCHAR', nullable: true),
    ColumnInfo(name: 'load_posts', type: 'INTEGER', nullable: true),
  ];

  test('cols, rels and loader clashes are left out, each with a warning; '
      'a relation written over several lines is read', () {
    final model = ModelSource.parse(shelf)!;
    expect(model.relations.map((r) => r.name), ['cols', 'posts', 'pages']);
    final plan = planAccessors(model, shelfColumns);
    // The column `cols` keeps its record field but no accessor; the
    // relation `cols` is left out; `posts` has no loader, since
    // `loadPosts` is the accessor of the column `load_posts`.
    expect(
      plan.lines,
      contains("    cols: ModelColumn<Shelf, String?>('cols'),"),
    );
    expect(plan.lines, isNot(contains(contains('get cols'))));
    expect(plan.lines, isNot(contains(contains("('cols'),\n"))));
    expect(
      plan.lines,
      isNot(contains(contains('RelationToken<Shelf, Book>(\'cols\')'))),
    );
    expect(
      plan.lines,
      contains("  ModelCollection<Book> get posts => related('posts');"),
    );
    expect(
      plan.lines,
      contains('  Future<ModelCollection<Book>> loadPages() async {'),
    );
    // `loadPosts` is the column's (field, getter, setter), never a loader.
    expect(plan.lines, isNot(contains(contains('loadPosts() async'))));
    expect(
      plan.warnings,
      containsAll([
        contains('Skipped column [cols]'),
        contains('Skipped relation [cols]'),
        contains(
          'Relation [posts]: no loadPosts(), the name of the column '
          'accessor loadPosts',
        ),
      ]),
    );
  });

  test('parses the relations map', () {
    expect(ModelSource.parse(writer)!.relations, [
      (name: 'books', kind: 'HasMany', related: 'Book'),
      (name: 'latestBook', kind: 'HasOne', related: 'Book'),
      (name: 'missing', kind: 'HasMany', related: 'Book'),
      (name: 'email', kind: 'HasOne', related: 'Book'),
      (name: 'key', kind: 'HasOne', related: 'Book'),
    ]);
    expect(ModelSource.parse(book)!.relations.last, (
      name: 'owner',
      kind: 'MorphTo',
      related: null,
    ));
  });

  test('rels, getters and loaders; clashes left out with a warning', () {
    final plan = planAccessors(ModelSource.parse(writer)!, writerColumns);
    expect(
      plan.lines,
      containsAll([
        '  static const rels = (',
        "    books: RelationToken<Writer, Book>('books'),",
        "    latestBook: RelationToken<Writer, Book>('latestBook'),",
        "  ModelCollection<Book> get books => related('books');",
        '  Future<ModelCollection<Book>> loadBooks() async {',
        "  Book? get latestBook => related('latestBook');",
        "  ModelCollection<Book> get missing => related('missing');",
      ]),
    );
    expect(plan.lines, isNot(contains(contains('loadMissing'))));
    expect(
      plan.lines,
      isNot(contains(contains("RelationToken<Writer, Book>('email')"))),
    );
    expect(plan.lines, isNot(contains(contains("('key')"))));
    expect(
      plan.warnings,
      containsAll([
        contains('Relation [missing]: no loadMissing()'),
        contains('Skipped relation [email]: `email` is already a column'),
        contains('Skipped relation [key]'),
      ]),
    );
  });

  test(
    'the synced models compile, and the tokens type the relations',
    () async {
      final dir = Directory(
        p.normalize(p.absolute('.dart_tool/typed_api_rels')),
      );
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      dir.createSync(recursive: true);
      String sync(String source, List<ColumnInfo> columns) =>
          syncModelSource(source, ModelSource.parse(source)!, columns).source!;
      File(p.join(dir.path, 'writer.dart'))
          .writeAsStringSync(sync(writer, writerColumns));
      File(p.join(dir.path, 'book.dart'))
          .writeAsStringSync(sync(book, bookColumns));
      File(p.join(dir.path, 'shelf.dart'))
          .writeAsStringSync(sync(shelf, shelfColumns));
      File(p.join(dir.path, 'use.dart')).writeAsStringSync('''
import 'package:daravel/daravel.dart';

import 'book.dart';
import 'writer.dart';

Future<void> use(Writer writer) async {
  final ModelCollection<Book> books = await writer.loadBooks();
  final Book? latest = writer.latestBook;
  final Model? owner = (await books.first.loadOwner());
  await Writer.definition
      .query()
      .with_([
        Writer.rels.books.nested(Book.rels.writer),
        Writer.rels.books.only([Book.cols.id, Book.cols.writerId]),
      ])
      .whereHas(Writer.rels.books)
      .get();
  print([latest, owner]);
}
''');
      final collection = AnalysisContextCollection(includedPaths: [dir.path]);
      final found = <String>[];
      for (final name in [
        'writer.dart',
        'book.dart',
        'shelf.dart',
        'use.dart',
      ]) {
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
        }
      }
      expect(found, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
