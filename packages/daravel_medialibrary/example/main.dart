import 'package:daravel/daravel.dart';
import 'package:daravel_medialibrary/daravel_medialibrary.dart';

/// A post with a cover image and a thumbnail made as it is uploaded.
final class Post extends Model with InteractsWithMedia {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title'],
    observers: [MediaObserver<Post>()],
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  @override
  void registerMediaCollections() {
    addMediaCollection('cover').singleFile();
  }

  @override
  void registerMediaConversions([Media? media]) {
    addMediaConversion('thumb').fit(Fit.crop, 300, 200).nonQueued();
  }
}

/// `POST /posts/{post}/cover` with a multipart `cover` field stores the
/// image under `storage/app/public/<media id>/` and answers its URLs.
Application createApp() =>
    Application.configure(basePath: '.')
        .withMediaLibrary()
        .withModels([Post.definition])
        .withMigrations(const [CreateMediaTable()])
        .withRouting(
          api: (router) {
            router.post('/posts/{post}/cover', (Request request) async {
              final post = (await Post.definition.query().find(
                request.param<int>('post'),
              ))!;
              final media = await post
                  .addMedia((await request.file('cover'))!)
                  .toMediaCollection('cover');
              return {'url': media.url(), 'thumb': media.url('thumb')};
            });
          },
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
