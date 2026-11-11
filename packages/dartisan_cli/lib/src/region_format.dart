/// Lays out the code `model:sync` and `request:sync` write into their
/// `// <dartisan:...>` regions as `dart format` would for the project, so a
/// synced file stays format-clean whatever the length of its names.
library;

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Formats generated region code with the project's language version and
/// page width. Only the code given is formatted, never the file around it.
final class RegionFormatter {
  /// A formatter for [languageVersion] (the latest when null) and
  /// [pageWidth].
  RegionFormatter({Version? languageVersion, this.pageWidth = 80})
    : languageVersion = languageVersion ?? DartFormatter.latestLanguageVersion;

  /// The formatter `dart format` uses in the project at [root]: the lower
  /// bound of the `sdk:` constraint in its `pubspec.yaml`, and the
  /// `formatter: page_width:` of its `analysis_options.yaml` (80 without).
  factory RegionFormatter.forProject(String root) => RegionFormatter(
    languageVersion: _sdkLowerBound(File(p.join(root, 'pubspec.yaml'))),
    pageWidth: _pageWidth(File(p.join(root, 'analysis_options.yaml'))) ?? 80,
  );

  /// The language version code is formatted for.
  final Version languageVersion;

  /// The page width.
  final int pageWidth;

  /// Why the last call returned its input unformatted, or null.
  String? lastFailure;

  DartFormatter get _formatter =>
      DartFormatter(languageVersion: languageVersion, pageWidth: pageWidth);

  /// [members] (class members, indented by two) as `dart format` lays them
  /// out inside a class. On a syntax error, [members] unchanged.
  String members(String members) {
    if (members.trim().isEmpty) {
      return members;
    }
    const head = 'class _Region {\n';
    try {
      final formatted = _formatter.format('$head$members\n}\n');
      final body = formatted.substring(
        formatted.indexOf('{\n') + 2,
        formatted.lastIndexOf('}'),
      );
      lastFailure = null;
      return body.trimRight();
    } on FormatterException catch (e) {
      lastFailure = e.message();
      return members;
    }
  }

  /// [code] (top-level declarations) as `dart format` lays it out. On a
  /// syntax error, [code] unchanged.
  String topLevel(String code) {
    try {
      final formatted = _formatter.format('$code\n');
      lastFailure = null;
      return formatted.trimRight();
    } on FormatterException catch (e) {
      lastFailure = e.message();
      return code;
    }
  }

  static Version? _sdkLowerBound(File pubspec) {
    if (!pubspec.existsSync()) {
      return null;
    }
    final match = RegExp(
      r'''^\s+sdk:\s*['"]?([^'"\n]+)''',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    if (match == null) {
      return null;
    }
    try {
      final constraint = VersionConstraint.parse(match.group(1)!.trim());
      final min = constraint is VersionRange ? constraint.min : null;
      return min == null ? null : Version(min.major, min.minor, 0);
    } on FormatException {
      return null;
    }
  }

  static int? _pageWidth(File options) {
    if (!options.existsSync()) {
      return null;
    }
    final match = RegExp(
      r'^formatter:\s*\n(?:[ \t]+.*\n)*?[ \t]+page_width:\s*(\d+)',
      multiLine: true,
    ).firstMatch(options.readAsStringSync());
    return match == null ? null : int.parse(match.group(1)!);
  }
}
