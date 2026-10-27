/// The `redis:*` commands (`redis:ping`, `redis:stats`, `redis:keys-audit`,
/// `redis:cli`), for `bootstrap/commands.dart`:
///
/// ```dart
/// import 'package:daravel_redis/commands.dart';
///
/// final List<CommandFactory> commands = [...redisCommands];
/// ```
///
/// A library of its own, so the server does not compile the CLI it needs.
library;

export 'src/commands.dart';
