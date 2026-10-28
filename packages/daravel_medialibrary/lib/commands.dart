/// The `media:regenerate` and `media:clean` commands, for
/// `bootstrap/commands.dart`:
///
/// ```dart
/// import 'package:daravel_medialibrary/commands.dart';
///
/// final List<CommandFactory> commands = [...mediaLibraryCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
