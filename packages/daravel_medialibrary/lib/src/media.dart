import 'dart:async';

import 'package:daravel/daravel.dart';

import 'media_library.dart';

/// A row of `media` (Spatie's `Media` model): a file attached to a model.
///
/// Files are stored as Spatie stores them, so a Laravel application on the
/// same database and disk serves them too: `<id>/<file_name>` on [disk],
/// conversions in `<id>/conversions/` on [conversionsDisk].
final class Media extends Model {
  static final ModelDefinition<Media> definition = ModelDefinition<Media>(
    table: 'media',
    factory: Media.new,
    guarded: const [],
    casts: const {
      'manipulations': Cast.json,
      'custom_properties': Cast.json,
      'generated_conversions': Cast.json,
      'responsive_images': Cast.json,
    },
    morphClass: r'Spatie\MediaLibrary\MediaCollections\Models\Media',
    observers: [_MediaObserver()],
  );

  @override
  ModelDefinition<Media> get modelDefinition => Media.definition;

  static ModelQuery<Media> query() => definition.query();

  /// Spatie's `findByUuid()`.
  static Future<Media?> findByUuid(String uuid) =>
      query().where('uuid', uuid).first();

  int get id => getAttr<num>('id').toInt();
  String? get uuid => getAttr('uuid');
  String get modelType => getAttr('model_type');
  Object get modelId => getAttr<Object>('model_id');
  String get collectionName => getAttr('collection_name');
  String get name => getAttr('name');
  String get fileName => getAttr('file_name');
  String? get mimeType => getAttr('mime_type');
  String get disk => getAttr('disk');
  String get conversionsDisk => getAttr<String?>('conversions_disk') ?? disk;
  int get size => getAttr<num>('size').toInt();
  int? get orderColumn => getAttr<num?>('order_column')?.toInt();
  DateTime? get createdAt => parseDateTime(getAttr<Object?>('created_at'));
  DateTime? get updatedAt => parseDateTime(getAttr<Object?>('updated_at'));

  /// The extension of [fileName], lower case.
  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  }

  /// `image`, `pdf` or `other` (Spatie's `type`).
  String get type {
    final mime = mimeType ?? '';
    if (mime.startsWith('image/')) {
      return 'image';
    }
    return mime == 'application/pdf' || extension == 'pdf' ? 'pdf' : 'other';
  }

  /// [size] as Spatie's `human_readable_size`: `1.5 KB`, `10 MB`.
  String get humanReadableSize => humanReadableFileSize(size);

  Map<String, Object?> get customProperties =>
      _map(getAttr<Object?>('custom_properties'));

  Map<String, Object?> get manipulations =>
      _map(getAttr<Object?>('manipulations'));

  /// The conversions and whether each was generated.
  Map<String, bool> get generatedConversions => {
    for (final MapEntry(:key, :value) in _map(
      getAttr<Object?>('generated_conversions'),
    ).entries)
      key: value == true,
  };

  bool hasCustomProperty(String name) =>
      dataGet(customProperties, name) != null;

  /// The custom property at the dot [path].
  Object? getCustomProperty(String path, [Object? defaultValue]) =>
      dataGet(customProperties, path) ?? defaultValue;

  /// Sets a custom property; call [save] to store it.
  Media setCustomProperty(String name, Object? value) {
    setAttr('custom_properties', {...customProperties, name: value});
    return this;
  }

  Media forgetCustomProperty(String name) {
    setAttr('custom_properties', {...customProperties}..remove(name));
    return this;
  }

  bool hasGeneratedConversion(String conversion) =>
      generatedConversions[conversion] ?? false;

  /// Records [conversion] as generated; call [save] to store it.
  Media markAsConversionGenerated(String conversion) {
    setAttr('generated_conversions', {
      ...generatedConversions,
      conversion: true,
    });
    return this;
  }

  Media markAsConversionNotGenerated(String conversion) {
    setAttr('generated_conversions', {
      ...generatedConversions,
      conversion: false,
    });
    return this;
  }

  /// The directory of this media on its disks (Spatie's
  /// `DefaultPathGenerator`): `<prefix>/<id>`.
  String get directory {
    final prefix = MediaLibrary.config.prefix;
    return prefix.isEmpty ? '$id' : '$prefix/$id';
  }

  /// The path of the file or of [conversion] relative to the root of its
  /// disk (Spatie's `getPathRelativeToRoot()`).
  String path([String conversion = '']) => conversion.isEmpty
      ? '$directory/$fileName'
      : '$directory/conversions/'
            '${MediaLibrary.conversionFileName(this, conversion)}';

  /// The URL of the file or of [conversion] (Spatie's `getUrl()`), whether
  /// or not the conversion was generated yet.
  String url([String conversion = '']) {
    final disk = Storage.disk(conversion.isEmpty ? this.disk : conversionsDisk);
    final url = disk.url(path(conversion));
    final updated = updatedAt;
    return MediaLibrary.config.versionUrls && updated != null
        ? '$url?v=${updated.millisecondsSinceEpoch ~/ 1000}'
        : url;
  }

  /// The URL of the first generated conversion of [conversions], else of
  /// the file (Spatie's `getAvailableUrl()`).
  String availableUrl(List<String> conversions) {
    for (final conversion in conversions) {
      if (hasGeneratedConversion(conversion)) {
        return url(conversion);
      }
    }
    return url();
  }

  /// The file's bytes.
  Future<List<int>> bytes([String conversion = '']) =>
      Storage.disk(conversion.isEmpty ? disk : conversionsDisk)
          .getBytes(path(conversion));

  /// Spatie's JSON: the attributes plus `original_url` and `preview_url`.
  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'original_url': url(),
    'preview_url': hasGeneratedConversion('preview') ? url('preview') : '',
  };

  /// Deletes the file, its conversions and the row; the rows of other
  /// media keep their files.
  Future<void> removeFiles() async {
    await Storage.disk(disk).deleteDirectory(directory);
    if (conversionsDisk != disk) {
      await Storage.disk(conversionsDisk).deleteDirectory(directory);
    }
  }

  static Map<String, Object?> _map(Object? value) => switch (value) {
    final Map<String, Object?> map => map,
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) '$key': value,
    },
    // Spatie stores an empty array as `[]`.
    _ => const {},
  };
}

/// Fills `uuid` and `order_column` on create and removes the files after a
/// delete, as Spatie's `HasUuid`, `IsSorted` and `MediaObserver` do.
final class _MediaObserver extends ModelObserver<Media> {
  const _MediaObserver();

  @override
  Future<bool?> creating(Media media) async {
    if ((media.uuid ?? '').isEmpty) {
      media.setAttr('uuid', Str.uuid());
    }
    if (media.getAttr<Object?>('order_column') == null) {
      final highest = await Media.query()
          .where('model_type', media.modelType)
          .where('model_id', media.modelId)
          .max('order_column');
      media.setAttr(
        'order_column',
        (highest is num
                ? highest.toInt()
                : int.tryParse('${highest ?? 0}') ?? 0) +
            1,
      );
    }
    for (final column in const [
      'manipulations',
      'custom_properties',
      'generated_conversions',
      'responsive_images',
    ]) {
      if (media.getAttr<Object?>(column) == null) {
        media.setAttr(column, const <Object?>[]);
      }
    }
    return null;
  }

  @override
  Future<bool?> deleted(Media media) async {
    await media.removeFiles();
    return null;
  }
}

/// Spatie's `File::getHumanReadableSize()`: two decimals at most, units up
/// to YB.
String humanReadableFileSize(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
  if (bytes == 0) {
    return '0 B';
  }
  var index = 0;
  var value = bytes.abs().toDouble();
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final rounded = (value * 100).round() / 100;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toString();
  return '$text ${units[index]}';
}
