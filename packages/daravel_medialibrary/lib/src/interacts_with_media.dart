import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'collection.dart';
import 'conversion.dart';
import 'file_adder.dart';
import 'media.dart';
import 'media_library.dart';

/// Files attached to a model (Spatie's `InteractsWithMedia`). Daravel has
/// no boot hooks, so the model also lists a [MediaObserver], which deletes
/// the media with the model:
///
/// ```dart
/// final class User extends Model with InteractsWithMedia {
///   static final ModelDefinition<User> definition = ModelDefinition<User>(
///     table: 'users',
///     factory: User.new,
///     observers: [MediaObserver<User>()],
///   );
///
///   @override
///   void registerMediaCollections() {
///     addMediaCollection('avatars').singleFile();
///   }
///
///   @override
///   void registerMediaConversions([Media? media]) {
///     addMediaConversion('thumb').fit(Fit.crop, 200, 200).nonQueued();
///   }
/// }
/// ```
base mixin InteractsWithMedia on Model {
  final List<MediaCollection> _collections = [];
  final List<Conversion> _conversions = [];
  bool _preservingMedia = false;

  /// Declares the collections with [addMediaCollection].
  void registerMediaCollections() {}

  /// Declares the conversions with [addMediaConversion]; [media] is the
  /// file they are for, when there is one.
  void registerMediaConversions([Media? media]) {}

  MediaCollection addMediaCollection(String name) {
    final collection = MediaCollection(name);
    _collections.add(collection);
    return collection;
  }

  Conversion addMediaConversion(String name) {
    final conversion = Conversion(name);
    _conversions.add(conversion);
    return conversion;
  }

  /// The declared collections.
  List<MediaCollection> get mediaCollections {
    _collections.clear();
    registerMediaCollections();
    return List.unmodifiable(_collections);
  }

  /// The collection [name]; an unrestricted one when it was not declared,
  /// as Spatie accepts any collection name.
  MediaCollection mediaCollection(String name) =>
      mediaCollections.where((c) => c.name == name).firstOrNull ??
      MediaCollection(name);

  /// The declared conversions for [media].
  List<Conversion> mediaConversions([Media? media]) {
    _conversions.clear();
    registerMediaConversions(media);
    return List.unmodifiable(_conversions);
  }

  /// Adds an uploaded file.
  FileAdder addMedia(UploadedFile file) => FileAdder(
    this,
    fileName: file.clientName,
    size: file.size,
    mimeType: file.mimeType,
    read: file.bytes,
  );

  /// Adds [bytes] as a file named [fileName].
  FileAdder addMediaFromBytes(List<int> bytes, {required String fileName}) {
    final data = Uint8List.fromList(bytes);
    return FileAdder(
      this,
      fileName: fileName,
      size: data.length,
      mimeType: detectMimeType(
        data.length > UploadedFile.headerLength
            ? Uint8List.sublistView(data, 0, UploadedFile.headerLength)
            : data,
      ),
      read: () async => data,
    );
  }

  /// Adds the local file at [path]; it is copied, not moved.
  Future<FileAdder> addMediaFromPath(String path) async {
    final bytes = await File(path).readAsBytes();
    return addMediaFromBytes(bytes, fileName: p.basename(path));
  }

  /// Adds the file of [disk] at [path] (Spatie's `addMediaFromDisk()`).
  Future<FileAdder> addMediaFromDisk(String path, {String? disk}) async {
    final bytes = await Storage.disk(disk).getBytes(path);
    return addMediaFromBytes(bytes, fileName: p.basename(path));
  }

  /// This model's media, in every collection.
  ModelQuery<Media> media() => Media.query()
      .where('model_type', Relation.morphClassOf(modelDefinition))
      .where('model_id', key);

  /// The media of [collection] in their order, those [filter] keeps.
  Future<List<Media>> getMedia([
    String collection = 'default',
    bool Function(Media media)? filter,
  ]) async {
    final items = await media()
        .where('collection_name', collection)
        .orderBy('order_column')
        .orderBy('id')
        .get();
    return [
      for (final item in items)
        if (filter == null || filter(item)) item,
    ];
  }

  Future<bool> hasMedia([String collection = 'default']) =>
      media().where('collection_name', collection).exists();

  Future<Media?> getFirstMedia([String collection = 'default']) async =>
      (await getMedia(collection)).firstOrNull;

  Future<Media?> getLastMedia([String collection = 'default']) async =>
      (await getMedia(collection)).lastOrNull;

  /// The URL of the first file of [collection] or of its [conversion];
  /// the collection's fallback URL, or `''`, when it is empty.
  Future<String> getFirstMediaUrl([
    String collection = 'default',
    String conversion = '',
  ]) async {
    final media = await getFirstMedia(collection);
    if (media == null) {
      final fallbacks = mediaCollection(collection).fallbackUrls;
      return fallbacks[conversion] ?? fallbacks[''] ?? '';
    }
    MediaLibrary.conversionsOf(this, media);
    return media.url(conversion);
  }

  /// The path of the first file of [collection] or of its [conversion]
  /// relative to the root of its disk; the fallback path, or `''`.
  Future<String> getFirstMediaPath([
    String collection = 'default',
    String conversion = '',
  ]) async {
    final media = await getFirstMedia(collection);
    if (media == null) {
      final fallbacks = mediaCollection(collection).fallbackPaths;
      return fallbacks[conversion] ?? fallbacks[''] ?? '';
    }
    MediaLibrary.conversionsOf(this, media);
    return media.path(conversion);
  }

  /// Deletes the media of [collection], their files included.
  Future<void> clearMediaCollection([String collection = 'default']) async {
    for (final media in await getMedia(collection)) {
      await media.delete();
    }
  }

  /// Deletes the media of [collection] except [keep] (media or ids).
  Future<void> clearMediaCollectionExcept(
    String collection,
    List<Object> keep,
  ) async {
    final ids = {
      for (final item in keep) item is Media ? item.id : int.parse('$item'),
    };
    for (final media in await getMedia(collection)) {
      if (!ids.contains(media.id)) {
        await media.delete();
      }
    }
  }

  /// Deletes one of this model's media by id.
  Future<void> deleteMedia(Object id) async {
    final media = await this.media().whereKey(id).first();
    if (media == null) {
      throw StateError('Media [$id] does not belong to this model.');
    }
    await media.delete();
  }

  /// Deletes every media of this model, in every collection.
  Future<void> deleteAllMedia() async {
    for (final media in await this.media().get()) {
      await media.delete();
    }
  }

  /// Deletes the model and keeps its media (Spatie's
  /// `deletePreservingMedia()`).
  Future<bool> deletePreservingMedia() async {
    _preservingMedia = true;
    try {
      return await delete();
    } finally {
      _preservingMedia = false;
    }
  }

  bool get shouldDeletePreservingMedia => _preservingMedia;
}

/// Deletes a model's media with the model (Spatie's
/// `bootInteractsWithMedia()`): on delete, or on force delete when the
/// model soft deletes, unless it was [InteractsWithMedia.deletePreservingMedia].
final class MediaObserver<T extends Model> extends ModelObserver<T> {
  const MediaObserver();

  @override
  Future<bool?> deleting(T model) async {
    if (!model.modelDefinition.softDeletes) {
      await _deleteMedia(model);
    }
    return null;
  }

  @override
  Future<bool?> forceDeleting(T model) async {
    await _deleteMedia(model);
    return null;
  }

  static Future<void> _deleteMedia(Model model) async {
    if (model is InteractsWithMedia && !model.shouldDeletePreservingMedia) {
      await model.deleteAllMedia();
    }
  }
}
