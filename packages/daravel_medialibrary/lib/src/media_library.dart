import 'dart:typed_data';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'conversion.dart';
import 'interacts_with_media.dart';
import 'jobs.dart';
import 'media.dart';

/// Lookups and conversion runs of the media library.
abstract final class MediaLibrary {
  /// The application's [MediaLibraryConfig], or the defaults when
  /// `withMediaLibrary()` was not called.
  static MediaLibraryConfig get config {
    final container = Container.current;
    if (container.bound<ConfigRepository>()) {
      final repository = container.make<ConfigRepository>();
      if (repository.hasSection<MediaLibraryConfig>()) {
        return repository.section<MediaLibraryConfig>();
      }
    }
    return const MediaLibraryConfig();
  }

  /// The model stored as [type] in `model_type`: its morph alias
  /// ([Relation.morphMap]) or a model of `withModels(...)` whose morph class
  /// is [type]; `null` when none.
  static ModelDefinition<Model>? definitionFor(String type) {
    final mapped = Relation.morphedModel(type);
    if (mapped != null) {
      return mapped;
    }
    final container = Container.current;
    if (container.bound<ModelRegistry>()) {
      for (final model in container.make<ModelRegistry>().models) {
        if (model.morphClass == type || Relation.morphClassOf(model) == type) {
          return model;
        }
      }
    }
    return null;
  }

  /// The model [media] belongs to, soft-deleted or not.
  static Future<InteractsWithMedia?> ownerOf(Media media) async {
    final definition =
        definitionFor(media.modelType) ??
        (throw StateError(
          'Cannot resolve the media owner type [${media.modelType}]: list '
          'its model in withModels(...) or register it with '
          'Relation.morphMap().',
        ));
    var query = definition.query();
    if (definition.softDeletes) {
      query = query.withTrashed();
    }
    final owner = await query.whereKey(media.modelId).first();
    return owner is InteractsWithMedia ? owner : null;
  }

  /// The file name of [conversion] of [media]: the conversion's own rules
  /// when the owner defines it, else Spatie's default (a JPEG).
  static String conversionFileName(Media media, String conversion) {
    final known = _conversionCache[media.modelType]?[conversion];
    return (known ?? Conversion(conversion)).fileName(media.fileName);
  }

  static final Map<String, Map<String, Conversion>> _conversionCache = {};

  /// Remembers [owner]'s conversions so [Media.url] names their files
  /// without loading the owner.
  static List<Conversion> conversionsOf(InteractsWithMedia owner, Media media) {
    final conversions = owner.mediaConversions(media);
    _conversionCache[media.modelType] = {
      ...?_conversionCache[media.modelType],
      for (final conversion in conversions) conversion.name: conversion,
    };
    return conversions;
  }

  /// Generates the conversions of [media]: the queued ones on the queue
  /// unless [now], the others here. [only] limits them by name;
  /// [onlyMissing] skips those already generated.
  static Future<void> performConversions(
    Media media, {
    InteractsWithMedia? owner,
    List<String>? only,
    bool onlyMissing = false,
    bool now = false,
  }) async {
    if (!canConvert(mimeType: media.mimeType, extension: media.extension)) {
      return;
    }
    final model = owner ?? await ownerOf(media);
    if (model == null) {
      return;
    }
    final conversions = [
      for (final conversion in conversionsOf(model, media))
        if (conversion.shouldBePerformedOn(media.collectionName) &&
            (only == null || only.contains(conversion.name)))
          conversion,
    ];
    final queued = <String>[];
    final immediate = <Conversion>[];
    for (final conversion in conversions) {
      if (!now && conversion.shouldBeQueued(config.queueConversionsByDefault)) {
        queued.add(conversion.name);
      } else {
        immediate.add(conversion);
      }
    }
    await _generate(media, immediate, onlyMissing: onlyMissing);
    if (queued.isNotEmpty) {
      final dispatch = Queue.dispatch(
        PerformConversionsJob(
          media.id,
          conversions: queued,
          onlyMissing: onlyMissing,
        ),
      );
      final queue = config.queueName;
      await (queue == null ? dispatch : dispatch.onQueue(queue));
    }
  }

  static Future<void> _generate(
    Media media,
    List<Conversion> conversions, {
    required bool onlyMissing,
  }) async {
    if (conversions.isEmpty) {
      return;
    }
    final target = Storage.disk(media.conversionsDisk);
    Uint8List? original;
    for (final conversion in conversions) {
      final path = media.path(conversion.name);
      if (onlyMissing &&
          media.hasGeneratedConversion(conversion.name) &&
          await target.exists(path)) {
        continue;
      }
      original ??= await Storage.disk(media.disk).getBytes(media.path());
      final converted = await convertImage(original, conversion.manipulations);
      await target.put(path, converted);
      media.markAsConversionGenerated(conversion.name);
    }
    if (media.isDirty()) {
      await media.save();
    }
  }
}
