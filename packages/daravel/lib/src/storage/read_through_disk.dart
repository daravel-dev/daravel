import 'dart:typed_data';

import 'storage.dart';

/// Laravel's `ReadThroughFilesystemAdapter`, for moving files to a new disk
/// without copying them all first: reads try [primary], then [fallback], and
/// a file found there moves up to [primary] unless [promote] is off. Writes
/// go to [primary]. Deletes reach both, or the file would come back.
///
/// A failed promotion does not fail the read, unless [throwOnPromotionFailure].
/// Listings show [primary] only, as in Laravel, and [url] is the primary's.
final class ReadThroughDisk implements Disk {
  ReadThroughDisk({
    required this.primary,
    required this.fallback,
    this.promote = true,
    this.throwOnPromotionFailure = false,
  });

  final Disk primary;
  final Disk fallback;
  final bool promote;
  final bool throwOnPromotionFailure;

  @override
  String get name => primary.name;

  Future<Disk> _readerFor(String path) async =>
      await primary.exists(path) ? primary : fallback;

  /// Writes to [primary]; answers whether that worked. Any failure counts: a
  /// local disk throws `FileSystemException`, S3 its own.
  Future<bool> _promote(Future<void> Function() write) async {
    try {
      await write();
      return true;
    } on Exception {
      if (throwOnPromotionFailure) {
        rethrow;
      }
      return false;
    }
  }

  @override
  Future<void> put(String path, Object contents) => primary.put(path, contents);

  @override
  Future<void> putStream(String path, Stream<List<int>> stream) =>
      primary.putStream(path, stream);

  @override
  Future<void> append(String path, String contents) async {
    if (!await primary.exists(path) && await fallback.exists(path)) {
      await primary.putStream(path, fallback.readStream(path));
    }
    await primary.append(path, contents);
  }

  @override
  Future<String> get(String path) async {
    if (await primary.exists(path)) {
      return primary.get(path);
    }
    final contents = await fallback.get(path);
    if (promote) {
      await _promote(() => primary.put(path, contents));
    }
    return contents;
  }

  @override
  Future<Uint8List> getBytes(String path) async {
    if (await primary.exists(path)) {
      return primary.getBytes(path);
    }
    final contents = await fallback.getBytes(path);
    if (promote) {
      await _promote(() => primary.put(path, contents));
    }
    return contents;
  }

  @override
  Stream<List<int>> readStream(String path) async* {
    if (await primary.exists(path)) {
      yield* primary.readStream(path);
    } else if (promote &&
        await _promote(
          () => primary.putStream(path, fallback.readStream(path)),
        )) {
      yield* primary.readStream(path);
    } else {
      yield* fallback.readStream(path);
    }
  }

  @override
  Future<bool> exists(String path) async =>
      await primary.exists(path) || await fallback.exists(path);

  @override
  Future<bool> missing(String path) async => !await exists(path);

  @override
  Future<bool> delete(Object paths) async {
    final list = paths is List ? paths.cast<String>() : [paths as String];
    var deleted = true;
    for (final path in list) {
      final onFallback = await fallback.exists(path);
      if (onFallback) {
        await fallback.delete(path);
      }
      final onPrimary = await primary.exists(path);
      if (onPrimary) {
        await primary.delete(path);
      }
      deleted = deleted && (onFallback || onPrimary);
    }
    return deleted;
  }

  Future<void> _ensureOnPrimary(String path) async {
    if (!await primary.exists(path)) {
      await primary.putStream(path, fallback.readStream(path));
    }
  }

  @override
  Future<void> copy(String from, String to) async {
    await _ensureOnPrimary(from);
    await primary.copy(from, to);
  }

  @override
  Future<void> move(String from, String to) async {
    await _ensureOnPrimary(from);
    await primary.move(from, to);
    if (await fallback.exists(from)) {
      await fallback.delete(from);
    }
  }

  @override
  Future<int> size(String path) async => (await _readerFor(path)).size(path);

  @override
  Future<DateTime> lastModified(String path) async =>
      (await _readerFor(path)).lastModified(path);

  @override
  String url(String path) => primary.url(path);

  @override
  Future<List<String>> files([String directory = '', bool recursive = false]) =>
      primary.files(directory, recursive);

  @override
  Future<List<String>> allFiles([String directory = '']) =>
      primary.allFiles(directory);

  @override
  Future<List<String>> directories([
    String directory = '',
    bool recursive = false,
  ]) => primary.directories(directory, recursive);

  @override
  Future<void> makeDirectory(String path) => primary.makeDirectory(path);

  @override
  Future<bool> deleteDirectory(String path) async {
    await fallback.deleteDirectory(path);
    return primary.deleteDirectory(path);
  }
}
