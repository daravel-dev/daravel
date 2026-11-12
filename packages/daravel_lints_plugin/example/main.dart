// The plugin runs inside the Dart analysis server, not as a program:
// enable it in the project's analysis_options.yaml and restart the
// analysis server (or run `dart analyze`):
//
//   plugins:
//     daravel_lints_plugin:
//       version: ^1.27.0
//       diagnostics:
//         prefer_sql_identifier: true   # an opt-in rule
//
// This program lists what the plugin registers: the rules on once it is
// enabled, and the opt-in ones `diagnostics:` turns on.
import 'package:daravel_lints_plugin/daravel_lints_plugin.dart';

void main() {
  final plugin = DaravelLintsPlugin();
  print('${plugin.name}: on once enabled');
  for (final rule in plugin.warnings) {
    print('  ${rule.name}: ${rule.description}');
  }
  print('opt-in (diagnostics: <rule>: true)');
  for (final rule in plugin.lints) {
    print('  ${rule.name}: ${rule.description}');
  }
}
