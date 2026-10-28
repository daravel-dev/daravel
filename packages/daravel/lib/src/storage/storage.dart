import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../foundation/config.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';

/// Raised for paths escaping the disk root or missing files.
final class StorageException extends DaravelException {
  const StorageException(super.message);
}

/// A filesystem abstraction (Laravel `Filesystem`; BLUEPRINT_V2 §7.10.1).
/// Paths are relative, `/`-separated and never escape the disk root.
abstract interface class Disk {
  String get name;

  /// Writes [contents] (`String` as UTF-8 or `List<int>`).
  Future<void> put(String path, Object contents);

  Future<void> putStream(String path, Stream<List<int>> stream);

  /// Appends a line (adds a newline when the file is not empty).
  Future<void> append(String path, String contents);

  Future<String> get(String path);

  Future<Uint8List> getBytes(String path);

  Stream<List<int>> readStream(String path);

  Future<bool> exists(String path);

  Future<bool> missing(String path);

  /// Deletes files; returns `true` when every one existed.
  Future<bool> delete(Object paths);

  Future<void> copy(String from, String to);

  Future<void> move(String from, String to);

  Future<int> size(String path);

  Future<DateTime> lastModified(String path);

  /// Public URL (only for disks with a `url`).
  String url(String path);

  /// Files directly inside [directory] (or recursively).
  Future<List<String>> files([String directory = '', bool recursive = false]);

  Future<List<String>> allFiles([String directory = '']);

  Future<List<String>> directories([
    String directory = '',
    bool recursive = false,
  ]);

  Future<void> makeDirectory(String path);

  Future<bool> deleteDirectory(String path);
}

/// Normalises a disk-relative path, rejecting traversal and absolute paths.
String normalizeDiskPath(String path) {
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
    // Windows truncates a name at a NUL (`report.pdf\0.txt` lands as
    // `report.pdf`, past any extension check made on the full name), and no
    // file name needs a control character.
    throw StorageException('Path contains a control character: [$path].');
  }
  final unified = path.replaceAll(r'\', '/');
  if (unified.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(unified)) {
    throw StorageException('Absolute paths are not allowed: [$path].');
  }
  final normalized = p.posix.normalize(unified);
  if (normalized == '..' || normalized.startsWith('../')) {
    throw StorageException('Path [$path] escapes the disk root.');
  }
  return normalized == '.' ? '' : normalized;
}

List<int> _bytesOf(Object contents) => switch (contents) {
  String() => utf8.encode(contents),
  List<int>() => contents,
  _ => throw ArgumentError.value(
    contents,
    'contents',
    'Expected a String or List<int>.',
  ),
};

/// Local filesystem disk rooted at [root].
final class LocalDisk implements Disk {
  LocalDisk(this.name, String root, {this.baseUrl})
    : root = p.normalize(p.absolute(root));

  @override
  final String name;
  final String root;

  /// Public URL prefix (`APP_URL/storage` for the public disk).
  final String? baseUrl;

  /// Absolute filesystem path for [path] (guarded against traversal).
  String path(String path) {
    final relative = normalizeDiskPath(path);
    final full = p.normalize(p.join(root, relative));
    if (full != root && !p.isWithin(root, full)) {
      throw StorageException('Path [$path] escapes the disk root.');
    }
    return full;
  }

  File _file(String relative) => File(path(relative));

  Future<File> _existing(String relative) async {
    final file = _file(relative);
    if (!await file.exists()) {
      throw StorageException('File not found at path: $relative');
    }
    return file;
  }

  @override
  Future<void> put(String path, Object contents) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(_bytesOf(contents), flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> putStream(String path, Stream<List<int>> stream) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    // Through a temporary file and a rename, like put: a stream that fails
    // half way used to leave a truncated file that exists() reported.
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final sink = temp.openWrite();
    try {
      await sink.addStream(stream);
      await sink.close();
      await temp.rename(file.path);
    } on Object {
      try {
        await sink.close();
      } on Object {
        // Already closed by the failure.
      }
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }

  @override
  Future<void> append(String path, String contents) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    final needsNewline = await file.exists() && await file.length() > 0;
    await file.writeAsString(
      needsNewline ? '\n$contents' : contents,
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<String> get(String path) async =>
      (await _existing(path)).readAsString();

  @override
  Future<Uint8List> getBytes(String path) async =>
      (await _existing(path)).readAsBytes();

  @override
  Stream<List<int>> readStream(String path) async* {
    yield* (await _existing(path)).openRead();
  }

  @override
  Future<bool> exists(String path) => _file(path).exists();

  @override
  Future<bool> missing(String path) async => !await exists(path);

  @override
  Future<bool> delete(Object paths) async {
    final list = paths is String
        ? <String>[paths]
        : (paths as List<Object?>).cast<String>();
    var all = true;
    for (final item in list) {
      final file = _file(item);
      if (await file.exists()) {
        await file.delete();
      } else {
        all = false;
      }
    }
    return all;
  }

  @override
  Future<void> copy(String from, String to) async {
    final source = await _existing(from);
    final target = _file(to);
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }

  @override
  Future<void> move(String from, String to) async {
    final source = await _existing(from);
    final target = _file(to);
    await target.parent.create(recursive: true);
    try {
      await source.rename(target.path);
    } on FileSystemException {
      await source.copy(target.path);
      await source.delete();
    }
  }

  @override
  Future<int> size(String path) async => (await _existing(path)).length();

  @override
  Future<DateTime> lastModified(String path) async =>
      (await (await _existing(path)).lastModified()).toUtc();

  @override
  String url(String path) {
    final base = baseUrl;
    if (base == null) {
      throw StorageException('Disk [$name] has no public URL.');
    }
    final relative = normalizeDiskPath(path);
    final encoded = relative.split('/').map(Uri.encodeComponent).join('/');
    return '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}/$encoded';
  }

  Future<List<String>> _list(
    String directory,
    bool recursive, {
    required bool dirs,
  }) async {
    final dir = Directory(path(directory));
    if (!await dir.exists()) {
      return const <String>[];
    }
    final result = <String>[];
    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity.path.endsWith('.tmp')) {
        continue;
      }
      if ((dirs && entity is Directory) || (!dirs && entity is File)) {
        result.add(p.relative(entity.path, from: root).replaceAll(r'\', '/'));
      }
    }
    return result..sort();
  }

  @override
  Future<List<String>> files([String directory = '', bool recursive = false]) =>
      _list(directory, recursive, dirs: false);

  @override
  Future<List<String>> allFiles([String directory = '']) =>
      files(directory, true);

  @override
  Future<List<String>> directories([
    String directory = '',
    bool recursive = false,
  ]) => _list(directory, recursive, dirs: true);

  @override
  Future<void> makeDirectory(String path) =>
      Directory(this.path(path)).create(recursive: true);

  @override
  Future<bool> deleteDirectory(String path) async {
    final dir = Directory(this.path(path));
    if (normalizeDiskPath(path).isEmpty) {
      throw const StorageException('Refusing to delete the disk root.');
    }
    if (!await dir.exists()) {
      return false;
    }
    await dir.delete(recursive: true);
    return true;
  }
}

/// In-memory disk (`Storage.fake()`), with assertions.
final class MemoryDisk implements Disk {
  MemoryDisk(this.name, {this.baseUrl});

  @override
  final String name;
  final String? baseUrl;

  final Map<String, ({Uint8List bytes, DateTime modified})> _files = {};
  final Set<String> _dirs = <String>{};

  @override
  Future<void> put(String path, Object contents) async {
    final key = normalizeDiskPath(path);
    _files[key] = (
      bytes: Uint8List.fromList(_bytesOf(contents)),
      modified: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> putStream(String path, Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    await put(path, builder.takeBytes());
  }

  @override
  Future<void> append(String path, String contents) async {
    final key = normalizeDiskPath(path);
    final existing = _files[key];
    final current = existing == null ? '' : utf8.decode(existing.bytes);
    await put(key, current.isEmpty ? contents : '$current\n$contents');
  }

  ({Uint8List bytes, DateTime modified}) _existing(String path) {
    final entry = _files[normalizeDiskPath(path)];
    if (entry == null) {
      throw StorageException('File not found at path: $path');
    }
    return entry;
  }

  @override
  Future<String> get(String path) async => utf8.decode(_existing(path).bytes);

  @override
  Future<Uint8List> getBytes(String path) async =>
      Uint8List.fromList(_existing(path).bytes);

  @override
  Stream<List<int>> readStream(String path) async* {
    yield _existing(path).bytes;
  }

  @override
  Future<bool> exists(String path) async =>
      _files.containsKey(normalizeDiskPath(path));

  @override
  Future<bool> missing(String path) async => !await exists(path);

  @override
  Future<bool> delete(Object paths) async {
    final list = paths is String
        ? <String>[paths]
        : (paths as List<Object?>).cast<String>();
    var all = true;
    for (final item in list) {
      all = _files.remove(normalizeDiskPath(item)) != null && all;
    }
    return all;
  }

  @override
  Future<void> copy(String from, String to) async =>
      _files[normalizeDiskPath(to)] = _existing(from);

  @override
  Future<void> move(String from, String to) async {
    await copy(from, to);
    _files.remove(normalizeDiskPath(from));
  }

  @override
  Future<int> size(String path) async => _existing(path).bytes.length;

  @override
  Future<DateTime> lastModified(String path) async => _existing(path).modified;

  @override
  String url(String path) {
    final base = baseUrl;
    if (base == null) {
      throw StorageException('Disk [$name] has no public URL.');
    }
    return '$base/${normalizeDiskPath(path)}';
  }

  bool _inDir(String file, String dir, bool recursive) {
    final prefix = dir.isEmpty ? '' : '$dir/';
    if (!file.startsWith(prefix)) {
      return false;
    }
    return recursive || !file.substring(prefix.length).contains('/');
  }

  @override
  Future<List<String>> files([
    String directory = '',
    bool recursive = false,
  ]) async {
    final dir = normalizeDiskPath(directory);
    return _files.keys.where((f) => _inDir(f, dir, recursive)).toList()..sort();
  }

  @override
  Future<List<String>> allFiles([String directory = '']) =>
      files(directory, true);

  @override
  Future<List<String>> directories([
    String directory = '',
    bool recursive = false,
  ]) async {
    final dir = normalizeDiskPath(directory);
    final all = <String>{..._dirs};
    for (final file in _files.keys) {
      final parts = file.split('/')..removeLast();
      for (var i = 1; i <= parts.length; i++) {
        all.add(parts.take(i).join('/'));
      }
    }
    return all.where((d) => d != dir && _inDir(d, dir, recursive)).toList()
      ..sort();
  }

  @override
  Future<void> makeDirectory(String path) async =>
      _dirs.add(normalizeDiskPath(path));

  @override
  Future<bool> deleteDirectory(String path) async {
    final dir = normalizeDiskPath(path);
    if (dir.isEmpty) {
      throw const StorageException('Refusing to delete the disk root.');
    }
    final before = _files.length;
    _files.removeWhere((key, _) => key.startsWith('$dir/'));
    final removedDir = _dirs.remove(dir);
    _dirs.removeWhere((d) => d.startsWith('$dir/'));
    return removedDir || _files.length < before;
  }

  /// Throws unless every path exists (optionally with [contents]).
  void assertExists(Object paths, [String? contents]) {
    final list = paths is String
        ? <String>[paths]
        : (paths as List<Object?>).cast<String>();
    for (final path in list) {
      final entry = _files[normalizeDiskPath(path)];
      if (entry == null) {
        throw StateError(
          'Unable to find a file at path [$path] on disk [$name].',
        );
      }
      if (contents != null && utf8.decode(entry.bytes) != contents) {
        throw StateError('File [$path] does not have the expected contents.');
      }
    }
  }

  void assertMissing(Object paths) {
    final list = paths is String
        ? <String>[paths]
        : (paths as List<Object?>).cast<String>();
    for (final path in list) {
      if (_files.containsKey(normalizeDiskPath(path))) {
        throw StateError(
          'Found unexpected file at path [$path] on disk [$name].',
        );
      }
    }
  }

  void assertDirectoryEmpty(String directory) {
    final dir = normalizeDiskPath(directory);
    if (_files.keys.any((f) => _inDir(f, dir, true))) {
      throw StateError('Directory [$directory] on disk [$name] is not empty.');
    }
  }
}

/// `FILESYSTEM_*` configuration (`config/filesystems.php`, Laravel 11).
final class StorageConfig implements ConfigSection {
  const StorageConfig({
    this.defaultDisk = 'local',
    this.localRoot = 'storage/app/private',
    this.publicRoot = 'storage/app/public',
    this.publicUrl = 'http://localhost:8000/storage',
    this.links = const <String, String>{'public/storage': 'storage/app/public'},
  });

  factory StorageConfig.fromEnv(Env env) {
    final appUrl = env.string('APP_URL', 'http://localhost:8000');
    final base = appUrl.endsWith('/')
        ? appUrl.substring(0, appUrl.length - 1)
        : appUrl;
    return StorageConfig(
      defaultDisk: env.string('FILESYSTEM_DISK', 'local'),
      localRoot: env.string('FILESYSTEM_LOCAL_ROOT', 'storage/app/private'),
      publicRoot: env.string('FILESYSTEM_PUBLIC_ROOT', 'storage/app/public'),
      publicUrl: env.string('FILESYSTEM_PUBLIC_URL', '$base/storage'),
    );
  }

  final String defaultDisk;
  final String localRoot;
  final String publicRoot;
  final String publicUrl;

  /// Symlinks created by `storage:link` (link → target, project-relative).
  final Map<String, String> links;

  @override
  String get key => 'filesystems';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'default': defaultDisk,
    'disks': {
      'local': {'driver': 'local', 'root': localRoot},
      'public': {'driver': 'local', 'root': publicRoot, 'url': publicUrl},
    },
    'links': links,
  };
}

/// Named disks (Laravel `FilesystemManager`).
final class StorageManager {
  StorageManager(this.config, {required this.basePath});

  final StorageConfig config;
  final String basePath;
  final Map<String, Disk Function()> _factories = {};
  final Map<String, Disk> _disks = <String, Disk>{};

  String _abs(String path) =>
      p.isAbsolute(path) ? path : p.join(basePath, path);

  /// Registers the standard `local` and `public` disks.
  StorageManager withDefaultDisks() {
    extend('local', () => LocalDisk('local', _abs(config.localRoot)));
    extend(
      'public',
      () => LocalDisk(
        'public',
        _abs(config.publicRoot),
        baseUrl: config.publicUrl,
      ),
    );
    return this;
  }

  void extend(String name, Disk Function() factory) {
    _factories[name] = factory;
    _disks.remove(name);
  }

  Iterable<String> get diskNames => _factories.keys;

  Disk disk([String? name]) {
    final resolved = name ?? config.defaultDisk;
    final existing = _disks[resolved];
    if (existing != null) {
      return existing;
    }
    final factory = _factories[resolved];
    if (factory == null) {
      throw ConfigException(
        'Disk [$resolved] is not defined (available: ${_factories.keys.join(', ')}).',
      );
    }
    return _disks[resolved] = factory();
  }

  /// Replaces [name] with an in-memory disk for tests.
  MemoryDisk fake([String? name]) {
    final resolved = name ?? config.defaultDisk;
    final disk = MemoryDisk(
      resolved,
      baseUrl: resolved == 'public' ? config.publicUrl : '/storage/$resolved',
    );
    _factories[resolved] = () => disk;
    _disks[resolved] = disk;
    return disk;
  }

  /// Creates the symlinks in [StorageConfig.links]; returns created paths.
  Future<List<String>> link({bool force = false}) async {
    final created = <String>[];
    for (final entry in config.links.entries) {
      final linkPath = _abs(entry.key);
      final target = _abs(entry.value);
      final link = Link(linkPath);
      if (await link.exists() || await Directory(linkPath).exists()) {
        if (!force) {
          continue;
        }
        if (await link.exists()) {
          await link.delete();
        }
      }
      await Directory(target).create(recursive: true);
      await Directory(p.dirname(linkPath)).create(recursive: true);
      await link.create(target);
      created.add(entry.key);
    }
    return created;
  }
}
