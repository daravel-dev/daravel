import '../foundation/container.dart';
import '../http/static_files.dart';

/// Versioned URLs of the files served by `ApplicationBuilder.withStatic`
/// (Laravel's `asset()` and `Vite::asset()`).
abstract final class Assets {
  /// The static directories of the current container.
  static StaticAssets get registry => Container.current.make<StaticAssets>();

  /// `/assets/neo.css?v=1a2b3c4d5e6f`: the URL of [path] with the version
  /// that lets browsers cache it for a year. A Vite source
  /// (`resources/js/app.js`) gives its built file.
  static String url(String path) => registry.url(path);

  /// The URL of the file Vite built from [entry] (`Vite::asset()`); throws
  /// when the manifest does not list it.
  static String vite(String entry) => registry.vite(entry);
}

/// Laravel's `asset()`: the versioned URL of a file served by
/// `withStatic` (`asset('neo.css')` → `/assets/neo.css?v=1a2b3c4d5e6f`).
String asset(String path) => Assets.url(path);
