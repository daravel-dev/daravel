/// A route's host: `admin.example.com` or `{tenant}.example.com`, where
/// `{tenant:slug}` also names the column of a model binding. A parameter is
/// one label, so it cannot swallow a dot.
final class DomainPattern {
  DomainPattern._(this.source, this.names, this.fields, this._regex);

  factory DomainPattern(String source) {
    final names = <String>[];
    final fields = <String, String>{};
    final buffer = StringBuffer('^');
    var position = 0;
    for (final match in _parameter.allMatches(source)) {
      _literal(source, source.substring(position, match.start), buffer);
      final name = match[1]!;
      final column = match[3];
      if (names.contains(name)) {
        throw ArgumentError.value(source, 'domain', 'Repeated parameter');
      }
      names.add(name);
      if (column != null) {
        fields[name] = column;
      }
      buffer.write('([^.]+)');
      position = match.end;
    }
    _literal(source, source.substring(position), buffer);
    buffer.write(r'$');
    return DomainPattern._(
      source,
      List.unmodifiable(names),
      Map.unmodifiable(fields),
      RegExp(buffer.toString(), caseSensitive: false),
    );
  }

  static final RegExp _parameter = RegExp(
    r'\{([A-Za-z_]\w*)(:([A-Za-z_]\w*))?\}',
  );
  static final RegExp _plain = RegExp(r'^[A-Za-z0-9.-]*$');

  static void _literal(String source, String text, StringBuffer buffer) {
    if (!_plain.hasMatch(text)) {
      throw ArgumentError.value(source, 'domain', 'Invalid domain pattern');
    }
    buffer.write(text.replaceAll('.', '[.]'));
  }

  final String source;

  /// The parameters, in order.
  final List<String> names;

  /// The columns of `{tenant:slug}`, by parameter.
  final Map<String, String> fields;

  final RegExp _regex;

  /// The parameters of [host], or `null` when it does not match.
  Map<String, String>? match(String host) {
    final found = _regex.firstMatch(host);
    if (found == null) {
      return null;
    }
    return {for (var i = 0; i < names.length; i++) names[i]: found[i + 1]!};
  }

  /// The host with [params] filled in; `null` values are for [missing].
  String fill(
    Map<String, Object?> params,
    Never Function(String name) missing,
  ) => source.replaceAllMapped(_parameter, (match) {
    final name = match[1]!;
    return '${params[name] ?? missing(name)}';
  });

  /// [host] without its port or the root dot, in lower case.
  static String normalize(String host) {
    var name = host.toLowerCase();
    if (!name.startsWith('[')) {
      final colon = name.indexOf(':');
      if (colon != -1) {
        name = name.substring(0, colon);
      }
    }
    return name.endsWith('.') ? name.substring(0, name.length - 1) : name;
  }
}
