// Migration registry (explicit, AOT-friendly). See BLUEPRINT_V2 ADR-002.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import '../database/migrations/m_2026_10_23_000001_create_users_table.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Migration> migrations = <Migration>[
  // Framework-provided: Sanctum-compatible `personal_access_tokens`.
  const CreatePersonalAccessTokensTable(),
  // <dartisan:entries>
  const CreateUsersTable(),
  // </dartisan:entries>
];
