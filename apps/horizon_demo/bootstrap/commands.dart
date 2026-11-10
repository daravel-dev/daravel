import 'package:daravel_horizon/commands.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

/// Console command registry.
final List<CommandFactory> commands = <CommandFactory>[
  // <dartisan:entries>
  ...horizonCommands,
  // </dartisan:entries>
];
