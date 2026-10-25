import 'dart:io';

/// Regenerates `packages/daravel/lib/src/translation/plural_rules.g.dart`
/// from Laravel's `MessageSelector.php` (any Laravel 12 checkout):
///
/// ```bash
/// dart run tool/translation/generate_plural_rules.dart \
///   <laravel>/vendor/laravel/framework/src/Illuminate/Translation/MessageSelector.php \
///   packages/daravel/lib/src/translation/plural_rules.g.dart
/// ```
///
/// The test fixture comes from `tool/translation/laravel_fixture.php`, run
/// with PHP inside a Laravel 12 application:
///
/// ```bash
/// php laravel_fixture.php > packages/daravel/test/translation/laravel_translation_fixture.json
/// ```
void main(List<String> args) {
  final php = File(args[0]).readAsStringSync();
  final start = php.indexOf('public function getPluralIndex');
  final body = php.substring(start, php.indexOf('default:', start));
  final lines = body.split('\n').map((l) => l.trim());
  final groups = <(List<String>, String)>[];
  var cases = <String>[];
  for (final line in lines) {
    final c = RegExp(r"^case '([^']+)':$").firstMatch(line);
    if (c != null) {
      cases.add(c[1]!);
      continue;
    }
    final r = RegExp(r'^return (.+);$').firstMatch(line);
    if (r != null && cases.isNotEmpty) {
      final expr = r[1]!
          .replaceAll(r'(int) $number', 'n')
          .replaceAll(r'$number', 'number')
          // PHP's % keeps the sign of the dividend, like Dart's remainder.
          .replaceAllMapped(
            RegExp(r'n % (\d+)'),
            (m) => 'n.remainder(${m[1]})',
          );
      groups.add((cases, expr));
      cases = [];
    }
  }
  final out = StringBuffer()
    ..writeln("// GENERATED from Laravel 12's MessageSelector::getPluralIndex")
    ..writeln('// (MIT; the rules come from Zend Framework, new BSD license).')
    ..writeln('// Do not edit by hand.')
    ..writeln()
    ..writeln('/// The plural form [number] takes in [locale] (Laravel\'s')
    ..writeln('/// `MessageSelector::getPluralIndex`); unknown locales use 0.')
    ..writeln('int pluralIndex(String locale, num number) {')
    ..writeln('  final n = number.toInt();')
    ..writeln('  switch (locale) {');
  for (final (locales, expr) in groups) {
    out.writeln('    case ${locales.map((l) => "'$l'").join(' || ')}:');
    out.writeln('      return $expr;');
  }
  out
    ..writeln('    default:')
    ..writeln('      return 0;')
    ..writeln('  }')
    ..writeln('}');
  File(args[1]).writeAsStringSync(out.toString());
  stdout.writeln(
    '${groups.length} groups, '
    '${groups.fold<int>(0, (s, g) => s + g.$1.length)} locales',
  );
}
