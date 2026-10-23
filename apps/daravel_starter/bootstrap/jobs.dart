// Job registry (explicit, AOT-friendly): name → factory from JSON.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import 'package:daravel_starter/app/jobs/send_welcome_email.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:job`; entries may also be added by hand.
final List<JobDefinition> jobs = <JobDefinition>[
  // <dartisan:entries>
  JobDefinition(SendWelcomeEmail.name, SendWelcomeEmail.fromJson),
  // </dartisan:entries>
];
