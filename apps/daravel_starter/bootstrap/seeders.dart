// Seeder registry (explicit, AOT-friendly). The first entry is the root seeder.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import '../database/seeders/database_seeder.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Seeder> seeders = <Seeder>[
  // <dartisan:entries>
  const DatabaseSeeder(),
  // </dartisan:entries>
];
