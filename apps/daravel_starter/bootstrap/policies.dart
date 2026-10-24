// Policy registry: model type → policy (Gate::policy).
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import 'package:daravel_starter/app/models/user.dart';
import 'package:daravel_starter/app/policies/user_policy.dart';

// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
void registerPolicies(AuthorizationGate gate) {
  // <dartisan:entries>
  gate.policy<User>(const UserPolicy());
  // </dartisan:entries>
}
