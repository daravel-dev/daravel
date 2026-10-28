/// The `make:export` and `make:import` commands, for
/// `bootstrap/commands.dart`:
///
/// ```dart
/// import 'package:daravel_excel/commands.dart';
///
/// final List<CommandFactory> commands = [...excelCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
