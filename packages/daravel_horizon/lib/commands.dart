/// The `dartisan` commands of `daravel_horizon`, for
/// `bootstrap/commands.dart` (what `dartisan pub:add horizon` writes):
///
/// ```dart
/// import 'package:daravel_horizon/commands.dart';
///
/// final List<CommandFactory> commands = [...horizonCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
