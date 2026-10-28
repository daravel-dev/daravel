// The Daravel side of bench/interop/medialibrary.sh: one step per run, on
// the SQLite database and the public disk a Laravel application with
// spatie/laravel-medialibrary uses too.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:image/image.dart' as img;

/// The same conversions as the Laravel side's User.
final class User extends Model with InteractsWithMedia {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    observers: [MediaObserver<User>()],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  @override
  void registerMediaConversions([Media? media]) {
    addMediaConversion('thumb').fit(Fit.crop, 100, 100).nonQueued();
    addMediaConversion('preview').width(300).nonQueued();
  }
}

Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.current.path)
      .withMediaLibrary()
      .withModels([User.definition])
      .withEnv({
        'APP_ENV': 'testing',
        'APP_URL': 'http://localhost',
        'LOG_LEVEL': 'error',
        'FILESYSTEM_PUBLIC_ROOT': '/shared/public',
        'QUEUE_CONNECTION': 'sync',
      })
      .create();
  await app.boot();
  (int, int) size(List<int> bytes) {
    final image = img.decodeImage(Uint8List.fromList(bytes))!;
    return (image.width, image.height);
  }

  final out = await app.run(() async {
    switch (args.first) {
      case 'read':
        final user = (await User.definition.query().find(int.parse(args[1])))!;
        final media = (await user.getFirstMedia('avatars'))!;
        final (tw, th) = size(await media.bytes('thumb'));
        final (pw, ph) = size(await media.bytes('preview'));
        return jsonEncode({
          'file': media.fileName,
          'mime': media.mimeType,
          'alt': media.getCustomProperty('alt'),
          'generated': media.generatedConversions,
          'thumb': [tw, th],
          'preview': [pw, ph],
          'url': await user.getFirstMediaUrl('avatars', 'thumb'),
          'size': media.size == (await media.bytes()).length,
        });
      case 'write':
        final user = (await User.definition.query().find(int.parse(args[1])))!;
        final image = img.Image(width: 600, height: 400);
        img.fill(image, color: img.ColorRgb8(30, 120, 200));
        final media = await user
            .addMediaFromBytes(
              img.encodeJpg(image),
              fileName: 'Daravel photo.jpg',
            )
            .withCustomProperties({'alt': 'from daravel'})
            .toMediaCollection('photos');
        return 'written ${media.id}';
      case 'delete':
        final media = (await Media.query()
            .whereKey(int.parse(args[1]))
            .first())!;
        await media.delete();
        final gone = !Directory('/shared/public/${args[1]}').existsSync();
        return gone ? 'deleted' : 'files left';
    }
    return 'unknown step';
  });
  stdout.writeln(out);
  await app.shutdown();
}
