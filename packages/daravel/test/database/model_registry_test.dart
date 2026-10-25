import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    hidden: ['password'],
    relations: {
      'articles': () =>
          HasMany<Article>(() => Article.definition, foreignKey: 'author_id'),
    },
  );
  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;
}

final class Article extends Model {
  static final ModelDefinition<Article> definition = ModelDefinition<Article>(
    table: 'articles',
    factory: Article.new,
    fillable: ['title', 'body'],
    softDeletes: true,
    casts: {'published_at': Cast.dateTime, 'meta': Cast.json},
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
      'notes': () =>
          MorphMany<Note>(() => Note.definition, morphName: 'notable'),
      'labels': () => BelongsToMany<Label>(
        () => Label.definition,
        pivotTable: 'article_label',
        foreignPivotKey: 'article_id',
        relatedPivotKey: 'label_id',
      ),
    },
  );
  @override
  ModelDefinition<Article> get modelDefinition => Article.definition;
}

final class Note extends Model {
  static final ModelDefinition<Note> definition = ModelDefinition<Note>(
    table: 'notes',
    factory: Note.new,
    relations: {
      'notable': () => MorphTo(types: [() => Article.definition]),
    },
  );
  @override
  ModelDefinition<Note> get modelDefinition => Note.definition;
}

final class Label extends Model {
  static final ModelDefinition<Label> definition = ModelDefinition<Label>(
    table: 'labels',
    factory: Label.new,
  );
  @override
  ModelDefinition<Label> get modelDefinition => Label.definition;
}

final List<ModelDefinition<Model>> models = [
  Author.definition,
  Article.definition,
  Note.definition,
  Label.definition,
];

void main() {
  test('withModels registers the models; find matches class, morph class '
      'or table', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withModels(models)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final registry = app.container.make<ModelRegistry>();
    expect(registry.models, hasLength(4));
    expect(registry.find('article'), same(Article.definition));
    expect(registry.find(r'App\Models\Author'), same(Author.definition));
    expect(registry.find('labels'), same(Label.definition));
    expect(registry.find('Missing'), isNull);
  });

  test('an application without models has an empty registry', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    expect(app.container.make<ModelRegistry>().models, isEmpty);
  });

  test('describeModel reports attributes, casts and relations', () {
    final article = describeModel(Article.definition);
    expect(article, containsPair('class', 'Article'));
    expect(article, containsPair('table', 'articles'));
    expect(article, containsPair('morphClass', r'App\Models\Article'));
    expect(article, containsPair('softDeletes', true));
    expect(article['fillable'], ['title', 'body']);
    expect(article['casts'], {'published_at': 'datetime', 'meta': 'json'});
    expect(article['relations'], [
      {
        'name': 'author',
        'type': 'BelongsTo',
        'related': 'Author',
        'foreignKey': 'author_id',
        'ownerKey': 'id',
      },
      {
        'name': 'notes',
        'type': 'MorphMany',
        'related': 'Note',
        'foreignKey': 'notable_id',
        'morphType': 'notable_type',
        'localKey': 'id',
      },
      {
        'name': 'labels',
        'type': 'BelongsToMany',
        'related': 'Label',
        'pivotTable': 'article_label',
        'foreignPivotKey': 'article_id',
        'relatedPivotKey': 'label_id',
      },
    ]);
    expect(describeModel(Author.definition)['relations'], [
      {
        'name': 'articles',
        'type': 'HasMany',
        'related': 'Article',
        'foreignKey': 'author_id',
        'localKey': 'id',
      },
    ]);
    expect(describeModel(Author.definition)['hidden'], ['password']);
    expect(describeModel(Note.definition)['relations'], [
      {
        'name': 'notable',
        'type': 'MorphTo',
        'related': ['Article'],
        'foreignKey': 'notable_id',
        'morphType': 'notable_type',
      },
    ]);
  });
}
