/// Entry point the Dart analysis server loads: enable the plugin in
/// `analysis_options.yaml` with `plugins: daravel_lints_plugin: ^1.27.0`.
library;

import 'src/plugin.dart';

/// The plugin the analysis server runs.
final plugin = DaravelLintsPlugin();
