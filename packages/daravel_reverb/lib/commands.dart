/// The `dartisan` commands of `daravel_reverb`, for
/// `bootstrap/commands.dart` (what `dartisan pub:add reverb` writes):
///
/// ```dart
/// import 'package:daravel_reverb/commands.dart';
///
/// final List<CommandFactory> commands = [...reverbCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
