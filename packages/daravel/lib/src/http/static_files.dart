import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'file_response.dart';
import 'http_exceptions.dart';
import 'request.dart';
import 'response.dart';

/// One file found by a [StaticFiles] scan.
final class StaticFile {
  StaticFile._(this.path, this.file, this.size, this.modified, this.version);

  /// The path under the directory, `/`-separated (`fonts/inter.woff2`).
  final String path;

  /// The file on disk, found by the scan.
  final File file;

  /// The size in bytes when the version was computed.
  int size;

  /// The modification time when the version was computed.
  DateTime modified;

  /// The first [StaticFiles.versionLength] hex digits of the SHA-256.
  String version;
}

/// A public directory served under a URL prefix (`ApplicationBuilder
/// .withStatic('public', prefix: '/assets')`), traversal-proof by
/// construction: the directory is scanned at boot and a request is
/// answered by looking its path up among the files found. No part of the
/// URL reaches the file system, so `..`, `%2e%2e`, backslashes or a
/// symbolic link planted later can only miss the lookup.
///
/// Dot files (`.env`, `.git`, `.vite`) and symbolic links are skipped: a
/// link such as `public/storage` (`storage:link`) leads to uploads, which
/// change at run time and are served by their disk instead.
///
/// A URL from [url] carries the file's version (`?v=<sha256 prefix>`) and
/// is answered with `Cache-Control: public, max-age=31536000, immutable`;
/// without it, or with a stale one, the answer may be cached for [maxAge]
/// only. Files a Vite build names by content hash are immutable either way.
final class StaticFiles {
  /// The files under [directory] (absolute), served under [prefix].
  StaticFiles(
    this.directory, {
    String prefix = '/assets',
    this.maxAge = const Duration(minutes: 5),
    this.rescan = false,
    this.buildDirectory = 'build',
  }) : prefix = _normalizePrefix(prefix);

  /// The name of the version manifest `dartisan static:hash` writes in the
  /// directory; a dot file, so it is never served.
  static const String manifestName = '.static-manifest.json';

  /// How many hex digits of the SHA-256 a version keeps.
  static const int versionLength = 12;

  /// The `Cache-Control` of a request carrying the current version.
  static const String immutable = 'public, max-age=31536000, immutable';

  /// The absolute directory.
  final String directory;

  /// The URL prefix, without a trailing slash (`''` for the root).
  final String prefix;

  /// How long a response without the current version may be cached.
  final Duration maxAge;

  /// Development mode (`APP_ENV=local` by default): a miss scans the
  /// directory again (at most once a second) and a changed file gets a new
  /// version, so new and edited files show up without a restart.
  final bool rescan;

  /// Vite's output directory under [directory] (`public/build`), where
  /// `manifest.json` maps sources to built files (Laravel's layout).
  final String buildDirectory;

  Map<String, StaticFile> _files = const {};
  Map<String, String> _vite = const {};
  Set<String> _fingerprinted = const {};
  DateTime? _scannedAt;

  static String _normalizePrefix(String prefix) {
    final trimmed = prefix.split('/').where((s) => s.isNotEmpty).join('/');
    return trimmed.isEmpty ? '' : '/$trimmed';
  }

  /// The route pattern serving the directory (`/assets/{path*}`).
  String get route => '$prefix/{path*}';

  /// The paths found, sorted.
  List<String> get paths => _files.keys.toList()..sort();

  /// Whether [path] (under the directory) was found.
  bool has(String path) => _lookup(_clean(path)) != null;

  /// Scans the directory and versions every file. A manifest written by
  /// `dartisan static:hash` supplies the versions of files whose size and
  /// modification time it recorded, so a production boot reads no file;
  /// [useManifest] `false` hashes everything.
  void scan({bool useManifest = true}) {
    final root = Directory(directory);
    if (!root.existsSync()) {
      throw FileSystemException('Static directory not found', directory);
    }
    final previous = _files;
    final recorded = useManifest && !rescan
        ? _readManifest()
        : const <String, StaticFile>{};
    final found = <String, StaticFile>{};
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final segments = p.split(p.relative(entity.path, from: directory));
      if (segments.any((s) => s.startsWith('.') || s.isEmpty)) {
        continue;
      }
      final path = segments.join('/');
      final stat = entity.statSync();
      final known = previous[path] ?? recorded[path];
      found[path] =
          known != null &&
              known.size == stat.size &&
              known.modified.millisecondsSinceEpoch ==
                  stat.modified.millisecondsSinceEpoch
          ? (StaticFile._(
              path,
              entity,
              stat.size,
              stat.modified,
              known.version,
            ))
          : StaticFile._(path, entity, stat.size, stat.modified, _hash(entity));
    }
    _files = found;
    _readVite();
    _scannedAt = DateTime.now();
  }

  /// The URL of [path] with its version (Laravel's `asset()` with a
  /// cache-busting query): `/assets/neo.css?v=1a2b3c4d5e6f`. A file of the
  /// Vite manifest (`resources/js/app.js`) gives its built file; any other
  /// path its plain URL, as `asset()` does not check that a file exists.
  String url(String path) {
    final clean = _clean(path);
    final file = _lookup(clean);
    if (file != null) {
      return '${_urlOf(file.path)}?v=${file.version}';
    }
    return viteUrl(clean) ?? _urlOf(clean);
  }

  /// The URL of the file Vite built from [entry] (`Vite::asset()`), or
  /// `null` when the manifest does not list it.
  String? viteUrl(String entry) {
    if (rescan) {
      _readVite();
    }
    final built = _vite[_clean(entry)];
    return built == null ? null : _urlOf(built);
  }

  /// The current version of [path], or `null` when it was not found.
  String? version(String path) => _lookup(_clean(path))?.version;

  /// Answers [request] for [path], the part of the URL after [prefix]:
  /// 404 unless the scan found exactly that path.
  Future<Response> serve(Request request, String path) async {
    final file = _lookup(path);
    if (file == null) {
      throw const NotFoundHttpException();
    }
    final versioned =
        _fingerprinted.contains(file.path) ||
        request.query['v'] == file.version;
    return sendStaticFile(
      file.file,
      contentType: mimeTypeOf(file.path),
      request: request,
      headers: {
        'cache-control': versioned
            ? immutable
            : 'public, max-age=${maxAge.inSeconds}',
      },
    );
  }

  /// The versions as `dartisan static:hash` writes them.
  Map<String, Object?> manifest() => {
    'version': 1,
    'files': {
      for (final path in paths)
        path: {
          'hash': _files[path]!.version,
          'size': _files[path]!.size,
          'modified': _files[path]!.modified.millisecondsSinceEpoch,
        },
    },
  };

  /// Hashes every file again and writes [manifestName]; returns its path.
  String writeManifest() {
    scan(useManifest: false);
    final target = p.join(directory, manifestName);
    File(target).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest())}\n',
    );
    return target;
  }

  StaticFile? _lookup(String path) {
    var file = _files[path];
    if (rescan) {
      if (file == null) {
        final last = _scannedAt;
        if (last == null ||
            DateTime.now().difference(last) >= const Duration(seconds: 1)) {
          scan();
          file = _files[path];
        }
      } else {
        _refresh(file);
      }
    }
    return file;
  }

  void _refresh(StaticFile file) {
    final stat = file.file.statSync();
    if (stat.type != FileSystemEntityType.file) {
      return;
    }
    if (stat.size != file.size || stat.modified != file.modified) {
      file
        ..size = stat.size
        ..modified = stat.modified
        ..version = _hash(file.file);
    }
  }

  String _urlOf(String path) =>
      '$prefix/${path.split('/').map(Uri.encodeComponent).join('/')}';

  static String _clean(String path) =>
      path.split('/').where((s) => s.isNotEmpty).join('/');

  static String _hash(File file) => sha256
      .convert(file.readAsBytesSync())
      .toString()
      .substring(0, versionLength);

  Map<String, StaticFile> _readManifest() {
    final file = File(p.join(directory, manifestName));
    if (!file.existsSync()) {
      return const {};
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      // Only an optimization: a broken manifest means hashing the files.
      return const {};
    }
    final files = decoded is Map<String, Object?> ? decoded['files'] : null;
    if (files is! Map<String, Object?>) {
      return const {};
    }
    return {
      for (final MapEntry(:key, :value) in files.entries)
        if (value case {
          'hash': final String hash,
          'size': final int size,
          'modified': final int modified,
        })
          key: StaticFile._(
            key,
            File(p.join(directory, key)),
            size,
            DateTime.fromMillisecondsSinceEpoch(modified),
            hash,
          ),
    };
  }

  /// Reads `<buildDirectory>/manifest.json` (laravel-vite-plugin) or
  /// `<buildDirectory>/.vite/manifest.json` (plain Vite 5+).
  void _readVite() {
    final build = _clean(buildDirectory);
    final candidates = [
      File(p.join(directory, build, 'manifest.json')),
      File(p.join(directory, build, '.vite', 'manifest.json')),
    ];
    final file = candidates.where((f) => f.existsSync()).firstOrNull;
    if (file == null) {
      _vite = const {};
      _fingerprinted = const {};
      return;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    final vite = <String, String>{};
    final fingerprinted = <String>{};
    if (decoded is Map<String, Object?>) {
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (value is! Map<String, Object?>) {
          continue;
        }
        if (value['file'] case final String built) {
          vite[key] = '$build/$built';
          fingerprinted.add('$build/$built');
        }
        for (final list in [value['css'], value['assets']]) {
          if (list is List<Object?>) {
            fingerprinted.addAll(
              list.whereType<String>().map((f) => '$build/$f'),
            );
          }
        }
      }
    }
    _vite = vite;
    _fingerprinted = fingerprinted;
  }
}

/// Every directory registered with `withStatic`, in order: [url] uses the
/// first that has the file. Bound in the container, read by `Assets`.
final class StaticAssets {
  /// The registry of [directories].
  StaticAssets([List<StaticFiles>? directories])
    : directories = directories ?? <StaticFiles>[];

  /// The registered directories.
  final List<StaticFiles> directories;

  /// The versioned URL of [path] (see [StaticFiles.url]); without any
  /// directory, `/<path>`.
  String url(String path) {
    for (final dir in directories) {
      if (dir.has(StaticFiles._clean(path))) {
        return dir.url(path);
      }
    }
    for (final dir in directories) {
      final built = dir.viteUrl(path);
      if (built != null) {
        return built;
      }
    }
    final first = directories.firstOrNull;
    return first == null ? '/${StaticFiles._clean(path)}' : first.url(path);
  }

  /// The URL of the file Vite built from [entry] (Laravel's
  /// `Vite::asset()`); throws when no manifest lists it, as Laravel does.
  String vite(String entry) {
    for (final dir in directories) {
      final built = dir.viteUrl(entry);
      if (built != null) {
        return built;
      }
    }
    throw StateError('Unable to locate file in Vite manifest: $entry.');
  }
}
