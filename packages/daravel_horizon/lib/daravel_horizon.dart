/// Daravel Horizon (Blueprint #134, ADR-033): queue supervisors in worker
/// isolates, auto-scaling and a dashboard, after Laravel Horizon.
///
/// This first slice holds the configuration ([HorizonConfig],
/// [SupervisorPlan]) and the auto-scaler ([decide]); the supervisor, the
/// store, the commands and the dashboard follow.
library;

export 'src/auto_scaler.dart';
export 'src/config.dart';
