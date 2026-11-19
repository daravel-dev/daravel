import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A conversion that runs in the request (`nonQueued()`, or queueing off)
/// and is refused: what the caller gets and what stays stored. The row and
/// the original are saved before the conversions run.
final class Gallery extends Model with InteractsWithMedia {
  static final ModelDefinition<Gallery> definition = ModelDefinition<Gallery>(
    table: 'galleries',
    factory: Gallery.new,
    fillable: ['title'],
    observers: [MediaObserver<Gallery>()],
  );

  @override
  ModelDefinition<Gallery> get modelDefinition => Gallery.definition;

  @override
  void registerMediaConversions([Media? media]) {
    addMediaConversion('thumb').width(50).nonQueued();
    // Far more pixels than the limits let a conversion make.
    addMediaConversion('huge').width(60000).nonQueued();
  }
}

final class CreateGalleries extends Migration {
  const CreateGalleries();

  @override
  String get name => '2026_01_01_000000_create_galleries';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('galleries', (table) {
    table.id();
    table.string('title');
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('galleries');
}

Uint8List jpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return img.encodeJpg(image);
}

void main() {
  late Directory dir;
  late Application app;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('daravel_media_request_');
    app = Application.configure(basePath: dir.path)
        .withMediaLibrary()
        .withEnv({
          'APP_ENV': 'testing',
          'APP_URL': 'https://example.test',
          'LOG_LEVEL': 'critical',
          'DB_DATABASE': '${dir.path}/app.sqlite',
          'QUEUE_CONNECTION': 'sync',
        })
        .withMigrations(const [CreateGalleries(), CreateMediaTable()])
        .withModels([Gallery.definition])
        .withRouting(
          apiPrefix: '',
          api: (router) => router.post('/upload', (request) async {
            final gallery = await Gallery.definition.query().create({
              'title': 'g',
            });
            final media = await gallery
                .addMediaFromBytes(jpeg(600, 400), fileName: 'a.jpg')
                .toMediaCollection();
            return {'id': media.id};
          }),
        )
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() async {
    await app.shutdown();
    dir.deleteSync(recursive: true);
  });

  File stored(String path) => File('${dir.path}/storage/app/public/$path');

  test('a refused conversion in the request: thrown to the caller, the row '
      'and the original stay, a conversion made before it is on disk but '
      'not recorded', () async {
    await app.run(() async {
      final gallery = await Gallery.definition.query().create({'title': 'g'});
      await expectLater(
        gallery
            .addMediaFromBytes(jpeg(600, 400), fileName: 'a.jpg')
            .toMediaCollection(),
        throwsA(isA<ImageTooLargeException>()),
      );
      final rows = await DB.table('media').get();
      expect(rows, hasLength(1), reason: 'the row stays');
      final row = rows.single;
      final id = row['id']! as int;
      expect(stored('$id/a.jpg').existsSync(), isTrue, reason: 'original');
      expect(
        stored('$id/conversions/a-thumb.jpg').existsSync(),
        isTrue,
        reason: 'the conversion before the refused one was written',
      );
      expect(
        jsonDecode(row['generated_conversions']! as String),
        anyOf(isEmpty, <String, Object?>{}),
        reason: 'but not recorded: the row was not saved again',
      );
    });
  });

  test('through HTTP: a 500, the row and the original stay', () async {
    final response = await app.handle(
      Request.fake(
        method: 'POST',
        path: '/upload',
        headers: {'accept': 'application/json'},
      ),
    );
    expect(response.status, 500);
    await app.run(() async {
      expect(await DB.table('media').get(), hasLength(1));
    });
  });
}
