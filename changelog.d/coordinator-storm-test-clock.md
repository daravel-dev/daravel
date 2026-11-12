### Added

- `RemoteCoordinatorChannel.refusalClockForTesting` (`@visibleForTesting`): replaces the wall clock that tells a refusal storm, so a test checks the storm rule without depending on how the operating system schedules the isolate. The coordinator's storm test uses it: on a loaded machine (CI) a descheduled isolate put more than the storm spacing between two ticks, which the rule rightly counted as no storm, and the test's exact bound failed.
