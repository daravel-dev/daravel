// Seeder registry; the first is the root seeder of `dartisan db:seed`.
import 'package:daravel/daravel.dart';

import '../database/seeders/demo_seeder.dart';

final List<Seeder> seeders = <Seeder>[
  // <dartisan:entries>
  const DemoSeeder(),
  // </dartisan:entries>
];
