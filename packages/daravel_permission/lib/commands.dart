/// The `permission:*` commands, for `bootstrap/commands.dart`:
///
/// ```dart
/// import 'package:daravel_permission/commands.dart';
///
/// final List<CommandFactory> commands = [...permissionCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
