import 'dart:typed_data';

import 'package:daravel/daravel.dart';

import 'collection.dart';
import 'interacts_with_media.dart';
import 'media.dart';
import 'media_library.dart';

/// Thrown when a file cannot be added: too big, a disallowed file name, or
/// refused by its collection.
final class FileCannotBeAdded extends DaravelException {
  FileCannotBeAdded(super.message);
}

/// Adds a file to a model (Spatie's `FileAdder`); finish with
/// [toMediaCollection].
///
/// ```dart
/// final media = await user
///     .addMedia((await request.file('avatar'))!)
///     .usingName('Avatar')
///     .withCustomProperties({'uploaded_by': user.id})
///     .toMediaCollection('avatars');
/// ```
final class FileAdder {
  FileAdder(
    this._subject, {
    required String fileName,
    required this._size,
    required this._mimeType,
    required this._read,
  }) : _fileName = fileName,
       _mediaName = _withoutExtension(fileName);

  final InteractsWithMedia _subject;
  String _fileName;
  final int _size;
  final String _mimeType;
  final Future<Uint8List> Function() _read;
  String _mediaName;
  Map<String, Object?> _customProperties = const {};
  Map<String, Object?> _manipulations = const {};
  int? _order;

  /// The `name` of the media (the file name without extension by default).
  FileAdder usingName(String name) {
    _mediaName = name;
    return this;
  }

  /// The stored file name; it is sanitized like any other.
  FileAdder usingFileName(String fileName) {
    _fileName = fileName;
    return this;
  }

  FileAdder withCustomProperties(Map<String, Object?> properties) {
    _customProperties = properties;
    return this;
  }

  /// Stored in `manipulations`, as Spatie's `withManipulations()`.
  FileAdder withManipulations(Map<String, Object?> manipulations) {
    _manipulations = manipulations;
    return this;
  }

  /// The `order_column`; after the model's last media by default.
  FileAdder setOrder(int order) {
    _order = order;
    return this;
  }

  /// Stores the file in [collection] on [disk] (the collection's disk, else
  /// `MEDIA_DISK`), runs or queues its conversions, and returns the media.
  Future<Media> toMediaCollection([
    String collection = 'default',
    String? disk,
  ]) async {
    if (!_subject.exists) {
      throw StateError(
        'Save the ${_subject.runtimeType} before adding media to it.',
      );
    }
    final config = MediaLibrary.config;
    if (_size > config.maxFileSize) {
      throw FileCannotBeAdded(
        'File has a size of ${humanReadableFileSize(_size)} which is greater '
        'than the maximum allowed ${humanReadableFileSize(config.maxFileSize)}',
      );
    }
    final fileName = sanitizeFileName(
      _fileName,
      disallowed: config.disallowedExtensions,
    );
    final mediaCollection = _subject.mediaCollection(collection);
    final pending = PendingFile(
      name: fileName,
      size: _size,
      mimeType: _mimeType,
    );
    if (!mediaCollection.accepts(pending)) {
      throw FileCannotBeAdded(
        'The file with properties `name: $fileName, size: $_size, mime: '
        '$_mimeType` was not accepted into the collection named '
        '`$collection` of model `${_subject.runtimeType}` with id '
        '`${_subject.key}`',
      );
    }
    final diskName = disk ?? mediaCollection.diskName ?? config.diskName;
    final media = Media()
      ..setAttr('model_type', Relation.morphClassOf(_subject.modelDefinition))
      ..setAttr('model_id', _subject.key)
      ..setAttr('collection_name', collection)
      ..setAttr('name', _mediaName)
      ..setAttr('file_name', fileName)
      ..setAttr('mime_type', _mimeType)
      ..setAttr('disk', diskName)
      ..setAttr(
        'conversions_disk',
        mediaCollection.conversionsDiskName ?? diskName,
      )
      ..setAttr('size', _size)
      ..setAttr(
        'custom_properties',
        _customProperties.isEmpty ? const <Object?>[] : _customProperties,
      )
      ..setAttr(
        'manipulations',
        _manipulations.isEmpty ? const <Object?>[] : _manipulations,
      )
      ..setAttr('generated_conversions', const <Object?>[])
      ..setAttr('responsive_images', const <Object?>[]);
    if (_order != null) {
      media.setAttr('order_column', _order);
    }
    await media.save();
    try {
      await Storage.disk(diskName).put(media.path(), await _read());
    } catch (_) {
      // No row without its file.
      await Media.query().whereKey(media.id).builder.delete();
      rethrow;
    }
    await _applyCollectionSizeLimit(mediaCollection);
    await MediaLibrary.performConversions(media, owner: _subject);
    // A queued conversion on the sync queue updated another instance of
    // the row.
    return await Media.query().whereKey(media.id).first() ?? media;
  }

  /// Keeps the newest `collectionSizeLimit` media of the collection.
  Future<void> _applyCollectionSizeLimit(MediaCollection collection) async {
    final limit = collection.collectionSizeLimit;
    if (limit == null) {
      return;
    }
    final items = await _subject.getMedia(collection.name);
    if (items.length <= limit) {
      return;
    }
    final keep = items.reversed.take(limit).map((m) => m.id).toSet();
    for (final item in items) {
      if (!keep.contains(item.id)) {
        await item.delete();
      }
    }
  }

  static String _withoutExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }
}

/// Spatie's `defaultSanitizer()`: removes control characters, turns spaces
/// into `-` and `#`, `/`, `\` into `-`; then refuses a name with a
/// [disallowed] extension in any segment (`shell.php.jpg` included).
String sanitizeFileName(String fileName, {List<String> disallowed = const []}) {
  final sanitized = fileName
      .replaceAll(RegExp(r'\p{C}+', unicode: true), '')
      .replaceAll(RegExp(r'\p{Z}', unicode: true), '-')
      .replaceAll(RegExp(r'[#/\\]'), '-');
  final segments = sanitized.toLowerCase().split('.').skip(1);
  for (final segment in segments) {
    if (disallowed.contains(segment)) {
      throw FileCannotBeAdded(
        'The file name `$fileName` (sanitized to `$sanitized`) has the '
        'disallowed extension `$segment`.',
      );
    }
  }
  return sanitized;
}
