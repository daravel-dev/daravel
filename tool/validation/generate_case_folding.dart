import 'dart:io';

/// Generates `packages/daravel/lib/src/validation/case_folding.g.dart` from
/// `tool/validation/CaseFolding-15.0.0.txt` (Unicode 15.0.0, status C and S).
///
/// Matches the simple case-folding table PCRE2's `maint/GenerateUcd.py`
/// builds for PHP 8.2-8.4 (bundled PCRE2 10.40/10.42/10.44, Unicode 14.0-15.0).
///
/// Run from the repository root:
/// `dart run tool/validation/generate_case_folding.dart`
/// Pass `--check` to verify the generated file is up to date.
void main(List<String> args) {
  const sourcePath = 'tool/validation/CaseFolding-15.0.0.txt';
  const targetPath = 'packages/daravel/lib/src/validation/case_folding.g.dart';
  const sourceUrl = 'https://www.unicode.org/Public/15.0.0/ucd/CaseFolding.txt';

  final source = File(sourcePath);
  if (!source.existsSync()) {
    stderr.writeln('Missing $sourcePath');
    exitCode = 1;
    return;
  }

  final entries = <(int, int)>[];
  for (final raw in source.readAsLinesSync()) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) {
      continue;
    }
    final parts = line.split(';').map((p) => p.trim()).toList();
    if (parts.length < 3) {
      continue;
    }
    final status = parts[1];
    if (status != 'C' && status != 'S') {
      continue;
    }
    final from = int.parse(parts[0], radix: 16);
    final to = int.parse(parts[2], radix: 16);
    entries.add((from, to));
  }

  String hex(int cp) =>
      '0x${cp.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  final out = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln('//')
    ..writeln('// Generator: tool/validation/generate_case_folding.dart')
    ..writeln('// Source: $sourceUrl')
    ..writeln('// © 2022 Unicode®, Inc.')
    ..writeln(
      '// Unicode and the Unicode Logo are registered trademarks of '
      'Unicode, Inc. in the U.S. and other countries.',
    )
    ..writeln(
      '// For terms of use, see https://www.unicode.org/terms_of_use.html',
    )
    ..writeln(
      '// Unicode version: 15.0.0 (status C and S, ${entries.length} rules)',
    )
    ..writeln('// Matches PCRE2 bundled with PHP 8.2-8.4 (Unicode 14.0-15.0).')
    ..writeln()
    ..writeln('/// Simple Unicode 15.0.0 case-folding table (status C and S).')
    ..writeln('///')
    ..writeln('/// Code points absent from this map fold to themselves.')
    ..writeln('const Map<int, int> unicodeCaseFolding = <int, int>{');

  for (final (from, to) in entries) {
    out.writeln('  ${hex(from)}: ${hex(to)},');
  }
  out.writeln('};');

  final content = '$out';
  final target = File(targetPath);
  if (args.contains('--check')) {
    final current = target.existsSync() ? target.readAsStringSync() : '';
    if (current != content) {
      stderr.writeln(
        '$targetPath is out of date. Run: '
        'dart run tool/validation/generate_case_folding.dart',
      );
      exitCode = 1;
    }
    return;
  }
  target.writeAsStringSync(content);
  stdout.writeln('Wrote ${entries.length} rules to $targetPath.');
}
