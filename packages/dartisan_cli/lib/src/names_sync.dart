/// What `dartisan names:sync` writes into `lib/app/names.dart`: the
/// application's registered names as constants and URL builders, so routes,
/// abilities, rate limiters, guards, disks and connections are completed
/// by the editor and checked by the compiler (wave 9, W9.6).
library;

import 'region_format.dart';

/// One named route: its [name], HTTP [methods], [path] and parameters.
typedef NamedRoute = ({String name, List<String> methods, String path});

/// The names `names:sync` reads from a booted application.
typedef AppNames = ({
  List<NamedRoute> routes,
  List<String> abilities,
  bool policies,
  List<String> rateLimiters,
  List<String> guards,
  List<String> disks,
  List<String> connections,
});

/// The policy abilities (`Gate.allows('update', [post])`), written once
/// when any policy is registered.
const List<String> policyAbilities = [
  'viewAny',
  'view',
  'create',
  'update',
  'delete',
  'restore',
  'forceDelete',
];

const String _start = '// <dartisan:names>';
const String _end = '// </dartisan:names>';

const Set<String> _reserved = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'type',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'query',
  'absolute',
};

/// A Dart name for [raw] (`posts.show` → `postsShow`, `update-post` →
/// `updatePost`), not one of [taken]: a name that is a keyword gets
/// `Name`, a clash gets `2`, `3`, ... and a [warnings] line.
String dartName(String raw, Set<String> taken, List<String> warnings) {
  final words = raw
      .split(RegExp('[^A-Za-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  var name = words.isEmpty
      ? 'unnamed'
      : [
          words.first[0].toLowerCase() + words.first.substring(1),
          for (final w in words.skip(1)) w[0].toUpperCase() + w.substring(1),
        ].join();
  if (RegExp('^[0-9]').hasMatch(name)) {
    name = 'n$name';
  }
  if (_reserved.contains(name)) {
    name = '${name}Name';
  }
  var candidate = name;
  for (var i = 2; taken.contains(candidate); i++) {
    candidate = '$name$i';
  }
  if (candidate != name) {
    warnings.add('[$raw] is written as $candidate: $name is already taken.');
  }
  taken.add(candidate);
  return candidate;
}

/// The parameters of [path] (`/posts/{post}/{slug?}`, `/files/{path*}`):
/// name and whether it is optional.
List<({String name, bool optional})> routeParams(String path) => [
  for (final m in RegExp(r'\{([A-Za-z0-9_]+)([?*]?)\}').allMatches(path))
    (name: m.group(1)!, optional: m.group(2) == '?'),
];

String _literal(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

/// The `<dartisan:names>` region for [names], and what it had to rename.
({String code, List<String> warnings}) namesRegion(AppNames names) {
  final warnings = <String>[];
  final out = StringBuffer()..writeln(_start);

  void constants(
    String type,
    String doc,
    Iterable<String> values, [
    String Function(String value)? wrap,
  ]) {
    final taken = <String>{};
    out
      ..writeln('/// $doc (written by `dartisan names:sync`).')
      ..writeln('abstract final class $type {');
    for (final value in values) {
      final field = dartName(value, taken, warnings);
      out.writeln(
        '  static const $field = ${wrap?.call(value) ?? _literal(value)};',
      );
    }
    out
      ..writeln('}')
      ..writeln();
  }

  // Routes: one URL builder per named route.
  final routeTaken = <String>{};
  out
    ..writeln(
      '/// The named routes, as URL builders (written by `dartisan '
      'names:sync`).',
    )
    ..writeln('abstract final class Routes {');
  final routeFields = <String, String>{};
  for (final route in names.routes) {
    final method = dartName(route.name, routeTaken, warnings);
    routeFields[route.name] = method;
    final params = routeParams(route.path);
    final paramTaken = <String>{'query', 'absolute'};
    final args = [
      for (final p in params)
        (
          raw: p.name,
          dart: dartName(p.name, paramTaken, warnings),
          optional: p.optional,
        ),
    ];
    out
      ..writeln(
        '  /// `${route.methods.join('|')} ${route.path}` (`${route.name}`).',
      )
      ..writeln('  static String $method({')
      ..writeAll([
        for (final a in args)
          a.optional
              ? '    Object? ${a.dart},\n'
              : '    required Object ${a.dart},\n',
      ])
      ..writeln('    Map<String, Object?> query = const {},')
      ..writeln('    bool absolute = false,')
      ..writeln('  }) => routeUrl(')
      ..writeln('    ${_literal(route.name)},')
      ..writeln('    params: {')
      ..writeAll([
        for (final a in args)
          a.optional
              ? '      ${_literal(a.raw)}: ?${a.dart},\n'
              : '      ${_literal(a.raw)}: ${a.dart},\n',
      ])
      ..writeln('    },')
      ..writeln('    query: query,')
      ..writeln('    absolute: absolute,')
      ..writeln('  );');
  }
  out
    ..writeln('}')
    ..writeln();

  constants(
    'RouteNames',
    'The route names, for APIs that take a name',
    names.routes.map((r) => r.name),
  );
  constants(
    'Abilities',
    'The abilities: `Gate.define` names, then the policy abilities',
    [
      ...names.abilities,
      if (names.policies)
        for (final a in policyAbilities)
          if (!names.abilities.contains(a)) a,
    ],
    (value) => 'Ability(${_literal(value)})',
  );
  constants(
    'RateLimiters',
    'The named rate limiters, for `Mw.throttle(...)`',
    names.rateLimiters,
  );
  constants('Guards', 'The auth guards', names.guards);
  constants('Disks', 'The storage disks', names.disks);
  constants('Connections', 'The database connections', names.connections);
  out.write(_end);
  return (code: out.toString(), warnings: warnings);
}

/// [source] (the current `lib/app/names.dart`, or null when there is none)
/// with its region written for [names] and laid out by [formatter].
({String source, List<String> warnings}) syncNamesSource(
  String? source,
  AppNames names, {
  RegionFormatter? formatter,
}) {
  final region = namesRegion(names);
  final warnings = [...region.warnings];
  var code = region.code;
  if (formatter != null) {
    final body = code.substring(_start.length, code.length - _end.length);
    final formatted = formatter.topLevel(body.trim());
    if (formatter.lastFailure == null) {
      code = '$_start\n$formatted\n$_end';
    } else {
      warnings.add(
        'The names region could not be formatted (${formatter.lastFailure}); '
        'written as generated.',
      );
    }
  }
  final base = source ?? "import 'package:daravel/daravel.dart';\n";
  final start = base.indexOf(_start);
  final end = base.indexOf(_end);
  if (start != -1 && end > start) {
    return (
      source:
          '${base.substring(0, start)}$code'
          '${base.substring(end + _end.length)}',
      warnings: warnings,
    );
  }
  final head = base.endsWith('\n') ? base : '$base\n';
  return (source: '$head\n$code\n', warnings: warnings);
}
