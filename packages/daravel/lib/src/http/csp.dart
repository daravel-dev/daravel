import 'dart:convert';
import 'dart:math';

/// A Content-Security-Policy, built directive by directive and sent by
/// `SecurityHeadersMiddleware(contentSecurityPolicy: ...)` on HTML
/// responses.
///
/// ```dart
/// final csp = Csp()
///   ..defaultSrc(['self'])
///   ..scriptSrc(['self', Csp.nonce])        // the request's 'nonce-...'
///   ..styleSrc(['self', 'unsafe-inline'])
///   ..imgSrc(['self', 'data:'])
///   ..formAction(['self', 'https://pay.example.com'])
///   ..frameAncestors(['none'])
///   ..baseUri(['none']);
/// ```
///
/// Keywords are quoted for you (`self` is written `'self'`, and so are
/// `none`, `unsafe-inline`, `unsafe-eval`, `strict-dynamic`, ... and
/// `nonce-...`/`sha256-...` sources); hosts and schemes
/// (`https://cdn.example.com`, `data:`, `*`) are written as given.
/// [Csp.nonce] stands for the request's nonce (`Request.cspNonce`), written
/// as `'nonce-<base64>'`. A source with whitespace, `;`, `,` or a stray
/// quote is refused, so a value from configuration cannot add a directive.
///
/// Configure a policy once, at boot: the middleware reads it on every
/// request.
final class Csp {
  /// An empty policy; [reportOnly] sends it as
  /// `Content-Security-Policy-Report-Only`, which reports violations without
  /// blocking anything (a way to try a policy on a live site).
  Csp({this.reportOnly = false});

  /// A strict starting point for a server-rendered site: everything from
  /// the site itself, inline scripts and styles only with the request's
  /// nonce, `data:` images, no plugins, no `<base>`, no framing, and forms
  /// posting only to the site.
  ///
  /// ```text
  /// default-src 'self'; script-src 'self' 'nonce-...';
  /// style-src 'self' 'nonce-...'; img-src 'self' data:; object-src 'none';
  /// base-uri 'none'; frame-ancestors 'none'; form-action 'self'
  /// ```
  factory Csp.strict({bool reportOnly = false}) => Csp(reportOnly: reportOnly)
    ..defaultSrc(const ['self'])
    ..scriptSrc(const ['self', nonce])
    ..styleSrc(const ['self', nonce])
    ..imgSrc(const ['self', 'data:'])
    ..objectSrc(const ['none'])
    ..baseUri(const ['none'])
    ..frameAncestors(const ['none'])
    ..formAction(const ['self']);

  /// The source that stands for the request's nonce.
  static const String nonce = 'nonce';

  /// The keywords written quoted.
  static const Set<String> keywords = {
    'self',
    'none',
    'unsafe-inline',
    'unsafe-eval',
    'unsafe-hashes',
    'unsafe-allow-redirects',
    'strict-dynamic',
    'report-sample',
    'wasm-unsafe-eval',
    'inline-speculation-rules',
    'trusted-types-eval',
  };

  /// Whether the policy is sent as `Content-Security-Policy-Report-Only`.
  final bool reportOnly;

  final Map<String, List<String>> _directives = {};

  static final Random _random = Random.secure();
  static final RegExp _directiveName = RegExp(r'^[a-z][a-z0-9-]*$');
  static final RegExp _hashOrNonce = RegExp(
    r'^(nonce|sha256|sha384|sha512)-[A-Za-z0-9+/_=-]+$',
  );
  static final RegExp _unsafe = RegExp('[\\s;,\'"\\x00-\\x1f\\x7f]');

  /// The header the policy is sent in.
  String get headerName => reportOnly
      ? 'content-security-policy-report-only'
      : 'content-security-policy';

  /// The directives and their sources as written (keywords quoted,
  /// [Csp.nonce] as is).
  Map<String, List<String>> get directives => {
    for (final MapEntry(:key, :value) in _directives.entries)
      key: List.unmodifiable(value),
  };

  /// Whether a directive lists [Csp.nonce], so each response needs one.
  bool get usesNonce => _directives.values.any((s) => s.contains(nonce));

  /// Adds [sources] to the directive [name] (`'script-src'`); a directive
  /// without sources (`upgrade-insecure-requests`) is written alone.
  /// Calling it again for the same directive adds to its sources.
  Csp directive(String name, [List<String> sources = const []]) {
    if (!_directiveName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Not a CSP directive name');
    }
    final list = _directives.putIfAbsent(name, () => <String>[]);
    for (final source in sources) {
      final written = _source(source);
      if (!list.contains(written)) {
        list.add(written);
      }
    }
    return this;
  }

  /// `default-src`: the fallback of every `*-src` directive not given.
  Csp defaultSrc(List<String> sources) => directive('default-src', sources);

  /// `script-src`.
  Csp scriptSrc(List<String> sources) => directive('script-src', sources);

  /// `style-src`.
  Csp styleSrc(List<String> sources) => directive('style-src', sources);

  /// `img-src`.
  Csp imgSrc(List<String> sources) => directive('img-src', sources);

  /// `font-src`.
  Csp fontSrc(List<String> sources) => directive('font-src', sources);

  /// `connect-src` (`fetch`, XHR, WebSocket, EventSource).
  Csp connectSrc(List<String> sources) => directive('connect-src', sources);

  /// `media-src`.
  Csp mediaSrc(List<String> sources) => directive('media-src', sources);

  /// `object-src` (`'none'` turns plugins off).
  Csp objectSrc(List<String> sources) => directive('object-src', sources);

  /// `frame-src`: what the page may embed.
  Csp frameSrc(List<String> sources) => directive('frame-src', sources);

  /// `worker-src`.
  Csp workerSrc(List<String> sources) => directive('worker-src', sources);

  /// `manifest-src`.
  Csp manifestSrc(List<String> sources) => directive('manifest-src', sources);

  /// `form-action`: where forms may be submitted. Chrome also applies it to
  /// the redirects that follow a form `POST`, so a form whose answer
  /// redirects to a payment gateway or an identity provider must list that
  /// host too.
  Csp formAction(List<String> sources) => directive('form-action', sources);

  /// `frame-ancestors`: who may frame the page (`'none'` is the CSP form of
  /// `X-Frame-Options: DENY`).
  Csp frameAncestors(List<String> sources) =>
      directive('frame-ancestors', sources);

  /// `base-uri`: what `<base href>` may point to.
  Csp baseUri(List<String> sources) => directive('base-uri', sources);

  /// `upgrade-insecure-requests`: load `http:` resources over `https:`.
  Csp upgradeInsecureRequests() => directive('upgrade-insecure-requests');

  /// `report-uri`: where browsers post violation reports.
  Csp reportUri(String uri) => directive('report-uri', [uri]);

  /// `report-to`: the `Reporting-Endpoints` group that receives reports.
  Csp reportTo(String group) => directive('report-to', [group]);

  /// The header value, with `'nonce-<nonce>'` in place of [Csp.nonce]
  /// (which is left out when [nonce] is `null`).
  String render({String? nonce}) {
    if (nonce != null && !_hashOrNonce.hasMatch('nonce-$nonce')) {
      throw ArgumentError.value(nonce, 'nonce', 'Not a base64 nonce');
    }
    return [
      for (final MapEntry(key: name, value: sources) in _directives.entries)
        [
          name,
          for (final source in sources)
            if (source != Csp.nonce)
              source
            else if (nonce != null)
              "'nonce-$nonce'",
        ].join(' '),
    ].join('; ');
  }

  @override
  String toString() => render();

  /// A new nonce: 16 bytes from a CSPRNG, base64 (24 characters).
  static String generateNonce() =>
      base64.encode([for (var i = 0; i < 16; i++) _random.nextInt(256)]);

  static String _source(String source) {
    final value = source.trim();
    if (value == nonce) {
      return value;
    }
    final quoted =
        value.length > 1 && value.startsWith("'") && value.endsWith("'");
    final bare = quoted ? value.substring(1, value.length - 1) : value;
    if (bare.isEmpty || _unsafe.hasMatch(bare)) {
      throw ArgumentError.value(source, 'source', 'Not a CSP source');
    }
    if (keywords.contains(bare.toLowerCase())) {
      return "'${bare.toLowerCase()}'";
    }
    if (_hashOrNonce.hasMatch(bare)) {
      return "'$bare'";
    }
    if (quoted) {
      throw ArgumentError.value(source, 'source', 'Unknown CSP keyword');
    }
    return bare;
  }
}
