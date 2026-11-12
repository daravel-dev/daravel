import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_style/dart_style.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:dartisan_cli/src/region_format.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `model:sync` writes a relation path extension next to each model
/// (Blueprint #155 Rev. 1 + R1.8): `Author.rels.books.pages` is
/// `books.pages`, checked at every step.
void main() {
  // An author has books; a book its author, its pages, an owner (MorphTo)
  // and relations model:sync cannot read or name; a page its book and the
  // page before it (a relation to its own model).
  const author = '''
import 'package:daravel/daravel.dart';

import 'book.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    relations: {
      'books': () => HasMany<Book>(() => Book.definition, foreignKey: 'author_id'),
    },
  );

  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const book = '''
import 'package:daravel/daravel.dart';

import 'author.dart';
import 'page.dart';

Relation<Page> _pagesOf() => HasMany<Page>(() => Page.definition, foreignKey: 'book_id');

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    relations: {
      'author': () => BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
      'pages':
          () =>
              HasMany<Page>(() => Page.definition, foreignKey: 'book_id'),
      'owner': () => MorphTo(),
      'only': () => HasMany<Page>(() => Page.definition, foreignKey: 'book_id'),
      'chapters': () {
        return HasMany<Page>(() => Page.definition, foreignKey: 'book_id');
      },
      'leaves': _pagesOf,
    },
  );

  @override
  ModelDefinition<Book> get modelDefinition => Book.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const page = '''
import 'package:daravel/daravel.dart';

import 'book.dart';

final class Page extends Model {
  static final ModelDefinition<Page> definition = ModelDefinition<Page>(
    table: 'pages',
    factory: Page.new,
    relations: {
      'book': () => BelongsTo<Book>(() => Book.definition, foreignKey: 'book_id'),
      'previous': () => BelongsTo<Page>(() => Page.definition, foreignKey: 'previous_id'),
    },
  );

  @override
  ModelDefinition<Page> get modelDefinition => Page.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
  const id = ColumnInfo(
    name: 'id',
    type: 'INTEGER',
    nullable: false,
    primary: true,
  );
  const authorColumns = [id];
  const bookColumns = [
    id,
    ColumnInfo(name: 'author_id', type: 'INTEGER', nullable: false),
  ];
  const pageColumns = [
    id,
    ColumnInfo(name: 'book_id', type: 'INTEGER', nullable: false),
    ColumnInfo(name: 'number', type: 'INTEGER', nullable: false),
    ColumnInfo(name: 'previous_id', type: 'INTEGER', nullable: true),
  ];

  ModelSync sync(
    String source,
    List<ColumnInfo> columns, {
    RegionFormatter? formatter,
  }) => syncModelSource(
    source,
    ModelSource.parse(source)!,
    columns,
    formatter: formatter ?? RegionFormatter(),
  );

  String region(String source) {
    const start = '// <dartisan:relation-path>';
    const end = '// </dartisan:relation-path>';
    final from = source.indexOf(start);
    expect(from, isNot(-1), reason: 'the region is written');
    return source.substring(from + start.length, source.indexOf(end)).trim();
  }

  // The code with its whitespace collapsed: dart format picks the breaks.
  String flat(String code) => code.replaceAll(RegExp(r'\s+'), ' ');

  test('one getter per relation with a rels entry, after the class', () {
    final synced = sync(book, bookColumns);
    final source = synced.source!;
    final code = flat(region(source));
    // After the class: the class closes after its accessors region.
    final classEnd = source.indexOf('\n}\n', source.indexOf('// </dartisan:'));
    expect(
      source.indexOf('// <dartisan:relation-path>'),
      greaterThan(classEnd),
      reason: 'a top-level region after the class',
    );
    expect(
      code,
      allOf(
        contains(
          'extension BookRelationPath<Root extends Model> '
          'on RelationToken<Root, Book> {',
        ),
        contains(
          'RelationToken<Root, Author> get author => nested(Book.rels.author);',
        ),
        contains(
          'RelationToken<Root, Page> get pages => nested(Book.rels.pages);',
        ),
        // MorphTo: a getter whose model is Model, where the path stops.
        contains(
          'RelationToken<Root, Model> get owner => nested(Book.rels.owner);',
        ),
        contains('/// The path, then `pages`: `<path>.pages`.'),
      ),
    );
    // `only` is a member of RelationToken: in rels, but no path getter.
    expect(source, contains("only: RelationToken<Book, Page>('only')"));
    expect(code, isNot(contains('get only')));
    expect(
      synced.warnings,
      contains(
        contains(
          'Relation [only]: no relation path getter, since `only` is a '
          'member of RelationToken; use .nested(Book.rels.only).',
        ),
      ),
    );
    // A closure with a body and a helper are not read: said, not silent.
    expect(
      synced.warnings,
      containsAll([
        contains('Relation [chapters] could not be read'),
        contains('Relation [leaves] could not be read'),
      ]),
    );
    expect(code, isNot(contains('chapters')));
  });

  test('the names skipped are exactly the members of RelationToken', () {
    for (final name in relationTokenMembers) {
      final source = page.replaceFirst("'previous'", "'$name'");
      final model = ModelSource.parse(source)!;
      final plan = relationPathPlan(model, const {});
      expect(
        plan.lines.join('\n'),
        isNot(contains('get $name ')),
        reason: name,
      );
    }
    // Any other name gets its getter.
    final plan = relationPathPlan(
      ModelSource.parse(page.replaceFirst("'previous'", "'named'"))!,
      const {},
    );
    expect(plan.lines.join('\n'), contains('get named =>'));
  });

  test('no extension on RelationToken<Root, Model>, ever', () {
    for (final (source, columns) in [
      (author, authorColumns),
      (book, bookColumns),
      (page, pageColumns),
    ]) {
      expect(
        sync(source, columns).source,
        isNot(contains('on RelationToken<Root, Model>')),
      );
    }
  });

  test('a relation to its own model; a model without relations', () {
    expect(
      flat(region(sync(page, pageColumns).source!)),
      contains(
        'RelationToken<Root, Page> get previous => nested(Page.rels.previous);',
      ),
    );
    const plain = '''
import 'package:daravel/daravel.dart';

final class Tag extends Model {
  static final ModelDefinition<Tag> definition = ModelDefinition<Tag>(
    table: 'tags',
    factory: Tag.new,
  );

  @override
  ModelDefinition<Tag> get modelDefinition => Tag.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
    expect(
      sync(plain, authorColumns).source,
      isNot(contains('relation-path')),
      reason: 'no relation, no region',
    );
  });

  test('synced twice is synced once; a region is emptied, not left stale', () {
    final once = sync(book, bookColumns).source!;
    expect(sync(once, bookColumns).source, once, reason: '--check is clean');
    // The relations removed from the model: the region stays, empty.
    final without = once.replaceFirst(
      RegExp(r"      'author': \(\) => BelongsTo<Author>[^\n]*\n"),
      '',
    );
    final emptied = region(sync(without, bookColumns).source!);
    expect(emptied, isNot(contains('get author')));
    final none = once
        .replaceFirst(RegExp(r'relations: \{[\s\S]*?\n    \},\n'), '')
        .replaceFirst("import 'author.dart';\n", '');
    expect(region(sync(none, bookColumns).source!), isEmpty);
  });

  for (final width in [80, 100]) {
    test('the region is format-clean at page width $width', () {
      final formatter = RegionFormatter(pageWidth: width);
      final dart = DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
        pageWidth: width,
      );
      final synced = sync(book, bookColumns, formatter: formatter);
      expect(synced.warnings, isNot(contains(contains('formatted'))));
      final code = region(synced.source!);
      expect(dart.format('$code\n'), '$code\n');
    });
  }

  test('paths of 2, 3 and 5 levels compile; a wrong step does not', () async {
    final dir = Directory(
      p.normalize(p.absolute('.dart_tool/typed_api_paths')),
    );
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    for (final (name, source, columns) in [
      ('author', author, authorColumns),
      ('book', book, bookColumns),
      ('page', page, pageColumns),
    ]) {
      File(p.join(dir.path, '$name.dart'))
          .writeAsStringSync(sync(source, columns).source!);
    }
    File(p.join(dir.path, 'use.dart')).writeAsStringSync('''
import 'package:daravel/daravel.dart';

import 'author.dart';
import 'book.dart';
import 'page.dart';

Future<void> use() async {
  final RelationToken<Author, Page> two = Author.rels.books.pages;
  final RelationToken<Author, Page> three = Author.rels.books.pages.previous;
  final RelationToken<Author, Book> five =
      Author.rels.books.author.books.pages.book;
  final RelationToken<Author, Model> owner = Author.rels.books.owner;
  await Author.definition
      .query()
      .with_([
        two,
        Author.rels.books.pages.only([Page.cols.id, Page.cols.number]),
        Author.rels.books.nested(Book.rels.only),
      ])
      .whereHas(three)
      .get();
  print([five, owner]);
}
''');
    File(p.join(dir.path, 'wrong.dart')).writeAsStringSync('''
import 'author.dart';

void wrong() {
  print(Author.rels.books.previous);
}
''');
    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    Future<List<String>> diagnostics(String name) async {
      final path = p.join(dir.path, name);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      return [
        if (result is ErrorsResult)
          for (final d in result.diagnostics)
            '$name:${result.lineInfo.getLocation(d.offset).lineNumber} '
                '${d.diagnosticCode.lowerCaseName}: ${d.message}',
      ];
    }

    final found = [
      for (final name in ['author.dart', 'book.dart', 'page.dart', 'use.dart'])
        ...await diagnostics(name),
    ];
    expect(found, isEmpty);
    // A book has no `previous`: the second step does not compile.
    expect(await diagnostics('wrong.dart'), [
      contains(
        "wrong.dart:4 undefined_instance_member_read: The member "
        "'previous' isn't defined for the type 'RelationToken<Author, Book>'",
      ),
    ]);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
