import 'package:daravel/daravel.dart';

import '../database/seeders/database_seeder.dart';

/// Seeder registry for CAT Exam application.
final List<Seeder> seeders = <Seeder>[const DatabaseSeeder()];
