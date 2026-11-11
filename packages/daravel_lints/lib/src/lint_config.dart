import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../daravel_lints.dart';

/// The name of the registry check, which runs on the project rather than
/// on one file (`checkRegistries`); `diagnostics:` turns it off by this
/// name like any rule.
const String registryRuleName = 'registry_entry_missing';

/// Which rules a project runs: [defaultRules], plus the [optionalRules]
/// in [enabled], minus the rules in [disabled].
///
/// Read from the project's `analysis_options.yaml` by [lintConfig], so
/// `dartisan lint`, `expectLintClean()` and the editor plugin agree.
final class LintConfig {
  /// A configuration; [lintConfig] reads one from a project.
  LintConfig({
    Iterable<String> enabled = const [],
    Iterable<String> disabled = const [],
    this.source,
    this.warnings = const [],
  }) : enabled = Set.unmodifiable(enabled),
       disabled = Set.unmodifiable(disabled) {
    _check(this.enabled);
    _check(this.disabled);
  }

  /// The rule names set to `true`.
  final Set<String> enabled;

  /// The rule names set to `false`.
  final Set<String> disabled;

  /// The block the names came from (`plugins: daravel_lints_plugin:
  /// diagnostics:` or `daravel_lints: diagnostics:`), `null` without one.
  final String? source;

  /// What the reader noticed and did not apply (a block it ignored).
  final List<String> warnings;

  /// Every rule name a configuration may set.
  static Set<String> get knownNames => {
    for (final rule in [...defaultRules, ...optionalRules]) rule.name,
    registryRuleName,
  };

  static void _check(Set<String> names) {
    final unknown = names.difference(knownNames);
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'Unknown Daravel lint rule ${unknown.join(', ')} '
        '(rules: ${(knownNames.toList()..sort()).join(', ')})',
      );
    }
  }

  /// The file rules to run.
  List<LintRule> get rules => [
    for (final rule in defaultRules)
      if (!disabled.contains(rule.name)) rule,
    for (final rule in optionalRules)
      if (enabled.contains(rule.name) && !disabled.contains(rule.name)) rule,
  ];

  /// Whether the registry check runs.
  bool get registries => !disabled.contains(registryRuleName);

  /// This configuration with [enable] turned on and [disable] turned off
  /// on top (`dartisan lint --enable=...`); a name in both is off.
  LintConfig withOverrides({
    Iterable<String> enable = const [],
    Iterable<String> disable = const [],
  }) {
    final off = {...disable};
    return LintConfig(
      enabled: {...enabled.difference(off), ...enable}.difference(off),
      disabled: {
        ...disabled.difference({...enable}),
        ...off,
      },
      source: source,
      warnings: warnings,
    );
  }
}

/// Reads the rules a project enables from `[root]/analysis_options.yaml`:
///
/// ```yaml
/// plugins:
///   daravel_lints_plugin:
///     diagnostics:
///       raw_env_outside_config: true   # an opt-in rule on
///       no_print_in_app: false         # a default rule off
/// ```
///
/// That block is the one the editor plugin reads. A project without the
/// plugin writes the same `diagnostics:` under a top-level `daravel_lints:`
/// block, which the analyzer ignores. When both exist, the plugin's wins
/// and [LintConfig.warnings] says the other was ignored, so the editor and
/// the command never differ.
///
/// Only [root]'s own file is read: in a pub workspace, the file of the
/// package `dartisan` runs in, not the workspace root's. `include:` is not
/// followed; a file with `include:` and no block of its own gets a warning.
///
/// Throws a [FormatException] for a malformed file or block and an
/// [ArgumentError] for a rule name that does not exist.
LintConfig lintConfig(String root) {
  final file = File(p.join(root, 'analysis_options.yaml'));
  if (!file.existsSync()) {
    return LintConfig();
  }
  final Object? yaml;
  try {
    yaml = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
  } on YamlException catch (error) {
    throw FormatException('analysis_options.yaml: ${error.message}');
  }
  if (yaml is! YamlMap) {
    return LintConfig();
  }
  const pluginSource = 'plugins: daravel_lints_plugin: diagnostics:';
  const ownSource = 'daravel_lints: diagnostics:';
  final plugin = _diagnostics(_path(yaml, ['plugins', 'daravel_lints_plugin']));
  final own = _diagnostics(yaml['daravel_lints']);
  if (plugin == null && own == null) {
    // A project's own included file may hold the block; a package's
    // (`package:lints/recommended.yaml`) does not, so it is not worth a
    // warning in every project.
    final include = yaml['include'];
    final includes = include is YamlList ? include.toList() : [include];
    final local = includes.any((i) => i is String && !i.startsWith('package:'));
    return LintConfig(
      warnings: [
        if (local)
          'analysis_options.yaml: include: is not followed for the Daravel '
              'lint rules; put $ownSource (or $pluginSource) in this file.',
      ],
    );
  }
  final (values, source) = plugin != null
      ? (plugin, pluginSource)
      : (own!, ownSource);
  final settings = <String, bool>{};
  for (final MapEntry(:key, :value) in values.entries) {
    if (value is! bool) {
      throw FormatException(
        'analysis_options.yaml ($source): $key must be true or false, '
        'not $value',
      );
    }
    settings['$key'] = value;
  }
  return LintConfig(
    enabled: [
      for (final e in settings.entries)
        if (e.value) e.key,
    ],
    disabled: [
      for (final e in settings.entries)
        if (!e.value) e.key,
    ],
    source: source,
    warnings: [
      if (plugin != null && own != null)
        'analysis_options.yaml: $ownSource is ignored, $pluginSource is '
            'read instead (the editor plugin reads that one).',
    ],
  );
}

Object? _path(YamlMap yaml, List<String> keys) {
  Object? node = yaml;
  for (final key in keys) {
    if (node is! YamlMap) {
      return null;
    }
    node = node[key];
  }
  return node;
}

/// The `diagnostics:` map under [block], `null` when there is none.
YamlMap? _diagnostics(Object? block) {
  if (block is! YamlMap) {
    return null;
  }
  final diagnostics = block['diagnostics'];
  if (diagnostics == null) {
    return null;
  }
  if (diagnostics is! YamlMap) {
    throw const FormatException(
      'analysis_options.yaml: diagnostics: must map rule names to true or '
      'false',
    );
  }
  return diagnostics;
}
