import 'package:daravel_reverb/commands.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

/// Console command registry.
final List<CommandFactory> commands = <CommandFactory>[
  // <dartisan:entries>
  ...reverbCommands,
  // </dartisan:entries>
];
