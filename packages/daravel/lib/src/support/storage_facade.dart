import 'dart:typed_data';

import '../foundation/container.dart';
import '../http/file_response.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../storage/storage.dart';

/// Filesystem access (`Storage::disk('public')->put(...)`).
abstract final class Storage {
  /// The storage manager of the current container.
  static StorageManager get manager => Container.current.make<StorageManager>();

  /// The disk [name] (`local`, `public`, `s3`...), or the default one.
  static Disk disk([String? name]) => manager.disk(name);

  /// Swaps [name] (default disk when `null`) for an in-memory disk.
  static MemoryDisk fake([String? name]) => manager.fake(name);

  /// Writes [contents] (a string or bytes) to [path] on the default disk.
  static Future<void> put(String path, Object contents) =>
      disk().put(path, contents);

  /// The text at [path].
  static Future<String> get(String path) => disk().get(path);

  /// The bytes at [path].
  static Future<Uint8List> getBytes(String path) => disk().getBytes(path);

  /// Whether [path] exists.
  static Future<bool> exists(String path) => disk().exists(path);

  /// Whether [path] does not exist.
  static Future<bool> missing(String path) => disk().missing(path);

  /// Deletes a path or a list of paths.
  static Future<bool> delete(Object paths) => disk().delete(paths);

  /// The size of [path] in bytes.
  static Future<int> size(String path) => disk().size(path);

  /// The public URL of [path].
  static String url(String path) => disk().url(path);

  /// The file at [path] as an attachment, from the default disk.
  static Future<Response> download(
    String path, {
    String? name,
    Map<String, String>? headers,
    Request? request,
  }) => disk().download(path, name: name, headers: headers, request: request);

  /// The file at [path], shown by the browser, from the default disk.
  static Future<Response> response(
    String path, {
    String? name,
    Map<String, String>? headers,
    Request? request,
  }) => disk().response(path, name: name, headers: headers, request: request);

  /// The files directly in [directory].
  static Future<List<String>> files([String directory = '']) =>
      disk().files(directory);
}
