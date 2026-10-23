import 'dart:typed_data';

import '../foundation/container.dart';
import '../storage/storage.dart';

/// Filesystem access (`Storage::disk('public')->put(...)`).
abstract final class Storage {
  static StorageManager get manager => Container.current.make<StorageManager>();

  static Disk disk([String? name]) => manager.disk(name);

  /// Swaps [name] (default disk when `null`) for an in-memory disk.
  static MemoryDisk fake([String? name]) => manager.fake(name);

  static Future<void> put(String path, Object contents) =>
      disk().put(path, contents);

  static Future<String> get(String path) => disk().get(path);

  static Future<Uint8List> getBytes(String path) => disk().getBytes(path);

  static Future<bool> exists(String path) => disk().exists(path);

  static Future<bool> missing(String path) => disk().missing(path);

  static Future<bool> delete(Object paths) => disk().delete(paths);

  static Future<int> size(String path) => disk().size(path);

  static String url(String path) => disk().url(path);

  static Future<List<String>> files([String directory = '']) =>
      disk().files(directory);
}
