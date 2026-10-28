/// Files and images attached to models (spatie/laravel-medialibrary v11):
/// the `media` table and file layout Spatie uses, so a Laravel application
/// on the same database and disk shares them, and image conversions in
/// pure Dart.
///
/// ```dart
/// final media = await user
///     .addMedia((await request.file('avatar'))!)
///     .toMediaCollection('avatars');
/// final thumb = await user.getFirstMediaUrl('avatars', 'thumb');
/// ```
library;

export 'src/collection.dart';
export 'src/config.dart';
export 'src/conversion.dart';
export 'src/file_adder.dart';
export 'src/interacts_with_media.dart';
export 'src/jobs.dart';
export 'src/media.dart';
export 'src/media_library.dart';
export 'src/migration.dart';
export 'src/setup.dart';
