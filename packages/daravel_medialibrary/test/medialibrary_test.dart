import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_medialibrary/commands.dart';
import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// Spatie's README model: an avatar, documents, a thumb now and a preview
/// on the queue.
final class Post extends Model with InteractsWithMedia {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title'],
    observers: [MediaObserver<Post>()],
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  int get id => getAttr<num>('id').toInt();

  @override
  void registerMediaCollections() {
    addMediaCollection('avatars').singleFile().useFallbackUrl('/avatar.png');
    addMediaCollection('documents').acceptsMimeTypes(['application/pdf']);
  }

  @override
  void registerMediaConversions([Media? media]) {
    addMediaConversion('thumb').fit(Fit.crop, 100, 100).nonQueued();
    addMediaConversion('preview').width(300).performOnCollections(['default']);
  }
}

/// Soft deletes: its media stay until a force delete.
final class Draft extends Model with InteractsWithMedia {
  static final ModelDefinition<Draft> definition = ModelDefinition<Draft>(
    table: 'drafts',
    factory: Draft.new,
    fillable: ['title'],
    softDeletes: true,
    observers: [MediaObserver<Draft>()],
  );

  @override
  ModelDefinition<Draft> get modelDefinition => Draft.definition;
}

final class CreateTables extends Migration {
  const CreateTables();

  @override
  String get name => '2026_01_01_000000_create_test_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('posts', (table) {
      table.id();
      table.string('title');
      table.timestamps();
    });
    await schema.create('drafts', (table) {
      table.id();
      table.string('title');
      table.timestamps();
      table.softDeletes();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('drafts');
    await schema.dropIfExists('posts');
  }
}

Uint8List jpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return img.encodeJpg(image);
}

(int, int) sizeOf(List<int> bytes) {
  final image = img.decodeImage(Uint8List.fromList(bytes))!;
  return (image.width, image.height);
}

void main() {
  late Directory dir;
  final apps = <Application>[];

  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'APP_ENV': 'testing',
    'APP_URL': 'https://example.test',
    'LOG_LEVEL': 'error',
    'DB_DATABASE': '${dir.path}/app.sqlite',
    'QUEUE_CONNECTION': 'sync',
    ...extra,
  };

  Application build([Map<String, String> extra = const {}]) =>
      Application.configure(basePath: dir.path)
          .withMediaLibrary()
          .withEnv(env(extra))
          .withMigrations(const [
            CreateTables(),
            CreateJobsTable(),
            CreateMediaTable(),
          ])
          .withModels([Post.definition, Draft.definition])
          .create();

  Future<Application> migrated([Map<String, String> extra = const {}]) async {
    final app = build(extra);
    await app.boot();
    apps.add(app);
    await app.run(() => App.make<Migrator>().run());
    return app;
  }

  File stored(String path) => File('${dir.path}/storage/app/public/$path');

  Directory folder(String path) =>
      Directory('${dir.path}/storage/app/public/$path');

  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_media_'));

  tearDown(() async {
    for (final app in apps) {
      await app.shutdown();
    }
    apps.clear();
    dir.deleteSync(recursive: true);
  });

  test('a file in Spatie\'s row and layout, its conversions', () async {
    final app = await migrated();
    await app.run(() async {
      final post = await Post.definition.query().create({'title': 'Hello'});
      final media = await post
          .addMedia(
            UploadedFile.fromBytes(jpeg(600, 400), name: 'my photo#1.JPG'),
          )
          .withCustomProperties({'alt': 'A red square'})
          .toMediaCollection();

      final row = await DB.table('media').where('id', media.id).first();
      expect(row!['model_type'], r'App\Models\Post');
      expect(row['model_id'], post.id);
      expect(row['collection_name'], 'default');
      expect(row['name'], 'my photo#1');
      expect(row['file_name'], 'my-photo-1.JPG');
      expect(row['mime_type'], 'image/jpeg');
      expect(row['disk'], 'public');
      expect(row['conversions_disk'], 'public');
      expect(row['order_column'], 1);
      expect(row['manipulations'], '[]');
      expect(row['responsive_images'], '[]');
      expect(jsonDecode(row['custom_properties']! as String), {
        'alt': 'A red square',
      });
      expect(jsonDecode(row['generated_conversions']! as String), {
        'thumb': true,
        'preview': true,
      });
      expect(row['uuid'], hasLength(36));

      expect(stored('${media.id}/my-photo-1.JPG').existsSync(), isTrue);
      expect(
        sizeOf(
          stored('${media.id}/conversions/my-photo-1-thumb.jpg')
              .readAsBytesSync(),
        ),
        (100, 100),
      );
      expect(
        sizeOf(
          stored('${media.id}/conversions/my-photo-1-preview.jpg')
              .readAsBytesSync(),
        ),
        (300, 200),
      );
      expect(
        media.url(),
        'https://example.test/storage/${media.id}/my-photo-1.JPG',
      );
      expect(
        await post.getFirstMediaUrl('default', 'thumb'),
        'https://example.test/storage/${media.id}/conversions/my-photo-1-thumb.jpg',
      );
      expect(media.humanReadableSize, endsWith('KB'));
      expect(media.getCustomProperty('alt'), 'A red square');
      expect(media.toJson()['preview_url'], contains('preview'));
    });
  });

  test('queued conversions wait for the worker', () async {
    final app = await migrated({'QUEUE_CONNECTION': 'database'});
    await app.run(() async {
      final post = await Post.definition.query().create({'title': 'Q'});
      final media = await post
          .addMediaFromBytes(jpeg(600, 400), fileName: 'q.jpg')
          .toMediaCollection();
      expect(media.generatedConversions, {'thumb': true});
      expect(await DB.table('jobs').count(), 1);
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      final fresh = (await Media.query().whereKey(media.id).first())!;
      expect(fresh.generatedConversions, {'thumb': true, 'preview': true});
      expect(
        stored('${media.id}/conversions/q-preview.jpg').existsSync(),
        isTrue,
      );
    });
  });

  test('single file collections, accepted types, file names, size', () async {
    final app = await migrated({'MEDIA_MAX_FILE_SIZE': '200000'});
    await app.run(() async {
      final post = await Post.definition.query().create({'title': 'A'});
      expect(await post.getFirstMediaUrl('avatars'), '/avatar.png');
      final first = await post
          .addMediaFromBytes(jpeg(50, 50), fileName: 'a.jpg')
          .toMediaCollection('avatars');
      final second = await post
          .addMediaFromBytes(jpeg(50, 50), fileName: 'b.jpg')
          .toMediaCollection('avatars');
      expect((await post.getMedia('avatars')).map((m) => m.id), [second.id]);
      expect(folder('${first.id}').existsSync(), isFalse);
      expect(second.orderColumn, 2);

      await expectLater(
        post
            .addMediaFromBytes(utf8.encode('plain'), fileName: 'notes.txt')
            .toMediaCollection('documents'),
        throwsA(isA<FileCannotBeAdded>()),
      );
      await expectLater(
        post
            .addMediaFromBytes(jpeg(10, 10), fileName: 'shell.php.jpg')
            .toMediaCollection(),
        throwsA(isA<FileCannotBeAdded>()),
      );
      await expectLater(
        post
            .addMediaFromBytes(Uint8List(300000), fileName: 'big.bin')
            .toMediaCollection(),
        throwsA(isA<FileCannotBeAdded>()),
      );
      expect(await Media.query().count(), 1);
    });
  });

  test('media go with their model, unless preserved or soft deleted', () async {
    final app = await migrated();
    await app.run(() async {
      final post = await Post.definition.query().create({'title': 'D'});
      final media = await post
          .addMediaFromBytes(jpeg(20, 20), fileName: 'd.jpg')
          .toMediaCollection();
      await post.delete();
      expect(await Media.query().count(), 0);
      expect(folder('${media.id}').existsSync(), isFalse);

      final kept = await Post.definition.query().create({'title': 'K'});
      await kept
          .addMediaFromBytes(jpeg(20, 20), fileName: 'k.jpg')
          .toMediaCollection();
      await kept.deletePreservingMedia();
      expect(await Media.query().count(), 1);

      final draft = await Draft.definition.query().create({'title': 'S'});
      await draft
          .addMediaFromBytes(utf8.encode('%PDF-1.4'), fileName: 's.pdf')
          .toMediaCollection();
      await draft.delete();
      expect(await Media.query().count(), 2);
      await draft.forceDelete();
      expect(await Media.query().count(), 1);
    });
  });

  test('media:regenerate and media:clean', () async {
    final app = await migrated();
    late Media media;
    await app.run(() async {
      final post = await Post.definition.query().create({'title': 'R'});
      media = await post
          .addMediaFromBytes(jpeg(600, 400), fileName: 'r.jpg')
          .toMediaCollection();
    });
    final thumb = stored('${media.id}/conversions/r-thumb.jpg')..deleteSync();
    stored('${media.id}/conversions/r-old.jpg').writeAsBytesSync([1]);
    stored('999/orphan.jpg')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1]);

    Future<int?> dartisan(List<String> args) =>
        DartisanRunner(build, commands: mediaLibraryCommands).run(args);

    expect(await dartisan(['media:regenerate', '--only-missing']), 0);
    expect(thumb.existsSync(), isTrue);
    expect(await dartisan(['media:clean', '--dry-run']), 0);
    expect(folder('999').existsSync(), isTrue);
    expect(await dartisan(['media:clean']), 0);
    expect(folder('999').existsSync(), isFalse);
    expect(stored('${media.id}/conversions/r-old.jpg').existsSync(), isFalse);
    expect(thumb.existsSync(), isTrue);
  });

  group('images', () {
    Map<String, List<Object?>> run(Conversion conversion) =>
        conversion.manipulations;

    (int, int) convert(Conversion conversion, int width, int height) =>
        sizeOf(convertImageSync(jpeg(width, height), run(conversion)));

    test('width and height apply one after the other, as Spatie', () {
      expect(convert(Conversion('a').width(200), 1000, 500), (200, 100));
      expect(convert(Conversion('a').height(100), 1000, 500), (200, 100));
      expect(convert(Conversion('a').width(200).height(200), 1000, 500), (
        400,
        200,
      ));
    });

    test('fit modes', () {
      Conversion fit(Fit f) => Conversion('f').fit(f, 300, 300);
      expect(convert(fit(Fit.contain), 600, 400), (300, 200));
      expect(convert(fit(Fit.contain), 150, 100), (300, 200));
      expect(convert(fit(Fit.max), 150, 100), (150, 100));
      expect(convert(fit(Fit.fill), 600, 400), (300, 300));
      expect(convert(fit(Fit.stretch), 600, 400), (300, 300));
      expect(convert(fit(Fit.crop), 600, 400), (300, 300));
      expect(convert(fit(Fit.fillMax), 150, 100), (300, 300));
      expect(
        convert(Conversion('c').crop(100, 50, CropPosition.topLeft), 600, 400),
        (100, 50),
      );
    });

    test('formats and file names', () {
      final png = Conversion('p').format(ImageFormat.png);
      expect(png.fileName('photo.jpg'), 'photo-p.png');
      expect(
        img.decodePng(convertImageSync(jpeg(10, 10), png.manipulations)),
        isNotNull,
      );
      expect(Conversion('t').fileName('scan.webp'), 'scan-t.jpg');
      expect(
        Conversion('k').keepOriginalImageFormat().fileName('a.png'),
        'a-k.png',
      );
      expect(
        () =>
            convertImageSync(Uint8List.fromList([1, 2, 3]), png.manipulations),
        throwsA(isA<ImageConversionException>()),
      );
    });
  });

  test('sizes read as Spatie prints them', () {
    expect(humanReadableFileSize(0), '0 B');
    expect(humanReadableFileSize(1000), '1000 B');
    expect(humanReadableFileSize(1536), '1.5 KB');
    expect(humanReadableFileSize(10 * 1024 * 1024), '10 MB');
    expect(sanitizeFileName('a\u0000b c#d/e\\f.jpg'), 'ab-c-d-e-f.jpg');
  });
}
