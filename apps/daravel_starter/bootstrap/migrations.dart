// Migration registry (explicit, AOT-friendly). See BLUEPRINT_V2 ADR-002.
import 'package:daravel/daravel.dart';

// <dartisan:imports>
import '../database/migrations/m_2026_10_23_000001_create_users_table.dart';

// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Migration> migrations = <Migration>[
  // Framework-provided: Sanctum-compatible `personal_access_tokens`.
  const CreatePersonalAccessTokensTable(),
  // Framework-provided: Laravel-compatible `cache` + `cache_locks`.
  const CreateCacheTable(),
  // Framework-provided: Laravel-compatible `jobs`, `job_batches`, `failed_jobs`.
  const CreateJobsTable(),
  // Framework-provided: Laravel Pennant's `features` (feature flags).
  const CreateFeaturesTable(),
  // <dartisan:entries>
  const CreateUsersTable(),
  // </dartisan:entries>
];
