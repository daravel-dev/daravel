import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_scout/daravel_scout.dart';

final class Post extends Model with Searchable {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    timestamps: false,
  );

  @override
  ModelDefinition<Post> get modelDefinition => definition;

  @override
  Map<String, Object?> toSearchableArray() => {'title': null, 'body': null};

  @override
  List<String> get searchUsingPrefix => const ['title'];
}

Future<void> main() async {
  final base = Directory.systemTemp.createTempSync('scout_example');
  final app = Application.configure(basePath: base.path)
      .withEnv({'APP_ENV': 'local', 'DB_DATABASE': ':memory:'})
      .create();
  await app.boot();
  await app.run(() async {
    await DB.statement(
      'CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, body TEXT)',
    );
    await DB.table('posts').insert([
      {'title': 'Laravel tips', 'body': 'Routes and queues'},
      {'title': 'Dart', 'body': 'Isolates for Laravel developers'},
    ]);
    for (final post in await Scout.search(Post.definition, 'laravel').get()) {
      stdout.writeln(post.getAttr<String>('title'));
    }
  });
  await app.shutdown();
  base.deleteSync(recursive: true);
}
