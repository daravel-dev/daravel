import '../foundation/locale.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';
import 'translator.dart';

/// Picks the request's locale from `?lang=` (or [query]) or the
/// `Accept-Language` header, among [supported], and makes it the locale of
/// the request: [trans], `App.locale` and validation messages follow it.
/// Without a match the application locale stays.
///
/// ```dart
/// middleware.use(const [SetLocaleMiddleware(supported: ['en', 'id'])]);
/// ```
final class SetLocaleMiddleware implements Middleware {
  const SetLocaleMiddleware({required this.supported, this.query = 'lang'});

  final List<String> supported;

  /// The query parameter that chooses the locale (`null` to ignore it).
  final String? query;

  @override
  Future<Response> handle(Request request, Next next) {
    final param = query;
    final locale =
        match(param == null ? null : request.query[param], supported) ??
        negotiate(request.header('accept-language'), supported);
    if (locale != null) {
      setCurrentLocale(locale);
      request.attributes['locale'] = locale;
    }
    return next(request);
  }

  /// The entry of [supported] for [tag] (`id-ID` matches `id_ID`, then
  /// `id`), ignoring case; `null` when none fits.
  static String? match(String? tag, List<String> supported) {
    if (tag == null || tag.isEmpty) {
      return null;
    }
    String normalize(String value) =>
        value.trim().replaceAll('-', '_').toLowerCase();
    final wanted = normalize(tag);
    final primary = wanted.split('_').first;
    for (final candidate in [wanted, primary]) {
      for (final locale in supported) {
        if (normalize(locale) == candidate) {
          return locale;
        }
      }
    }
    return null;
  }

  /// The best of [supported] for an `Accept-Language` [header]
  /// (`id-ID,id;q=0.9,en;q=0.8`): highest quality first, `q=0` excluded.
  static String? negotiate(String? header, List<String> supported) {
    if (header == null || header.trim().isEmpty) {
      return null;
    }
    final ranges = <({String tag, double quality, int order})>[];
    final parts = header.split(',');
    for (var i = 0; i < parts.length; i++) {
      final pieces = parts[i].split(';');
      final tag = pieces.first.trim();
      var quality = 1.0;
      for (final parameter in pieces.skip(1)) {
        final kv = parameter.trim().split('=');
        if (kv.length == 2 && kv.first.trim() == 'q') {
          quality = double.tryParse(kv.last.trim()) ?? 0;
        }
      }
      if (tag.isNotEmpty && tag != '*' && quality > 0) {
        ranges.add((tag: tag, quality: quality, order: i));
      }
    }
    ranges.sort(
      (a, b) => a.quality == b.quality
          ? a.order.compareTo(b.order)
          : b.quality.compareTo(a.quality),
    );
    for (final range in ranges) {
      final locale = match(range.tag, supported);
      if (locale != null) {
        return locale;
      }
    }
    return null;
  }
}
