// Command registry for bin/dartisan.dart.
import 'package:daravel_activitylog/commands.dart';
import 'package:daravel_permission/commands.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

final List<CommandFactory> commands = <CommandFactory>[
  // <dartisan:entries>
  ...permissionCommands,
  ...activitylogCommands,
  // </dartisan:entries>
];
