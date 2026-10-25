// Model registry (explicit, AOT-friendly): read by `dartisan model:show`
// and `dartisan mcp:serve`.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import 'package:daravel_starter/app/models/user.dart';

// </dartisan:imports>

/// Maintained by `dartisan make:model`; entries may also be added by hand.
final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  // <dartisan:entries>
  User.definition,
  // </dartisan:entries>
];
