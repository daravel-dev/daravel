/// The `activitylog:clean` command, for `bootstrap/commands.dart`:
///
/// ```dart
/// import 'package:daravel_activitylog/commands.dart';
///
/// final List<CommandFactory> commands = [...activitylogCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
