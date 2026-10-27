import 'package:daravel/daravel.dart';
import 'package:daravel_teorion/daravel_teorion.dart';

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;
}

final class PostQueryFilter extends QueryFilter<Post> {
  @override
  Map<String, Filter> get filters => {'q': Filter.like('title')};

  @override
  List<String> get allowedSorts => ['id', 'title'];
}

/// `GET /api/posts?q=dart&sort=-id&is_paginate=1`.
Application createApp() =>
    Application.configure(basePath: '.')
        .withQueryFilters({Post: PostQueryFilter.new})
        .withRouting(
          api: (router) => router.get(
            '/posts',
            (request) => Post.definition.query().filterAndPaginate(request),
          ),
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
