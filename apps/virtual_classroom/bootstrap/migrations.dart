// Migration registry (explicit, AOT-friendly).
import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';
import 'package:daravel_permission/daravel_permission.dart';

// <dartisan:imports>
import '../database/migrations/m_2026_10_28_000001_create_classroom_tables.dart';

// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Migration> migrations = <Migration>[
  const CreatePersonalAccessTokensTable(),
  const CreateCacheTable(),
  const CreateJobsTable(),
  // <dartisan:entries>
  const CreateClassroomTables(),
  const CreatePermissionTables(),
  const CreateActivityLogTable(),
  // </dartisan:entries>
];
