### Added

- `dartisan doctor` warns about jobs nobody takes (#453). With `QUEUE_CONNECTION=database`, every queue with jobs available for more than five minutes and not reserved gets a warning (*N job(s) on queue [lifecycle] waiting over 5 minutes*), with the likely cause. The embedded worker takes only the default queue unless `SERVER_EMBED_QUEUES` lists more, so a job dispatched with `.onQueue('lifecycle')` was stored and never ran, silently. The warning gives the `SERVER_EMBED_QUEUES` value to set, says that a listed queue's worker is behind or not running, or, without an embedded worker, suggests `queue:work --queue=...`. A separate worker that keeps up leaves no such jobs and gives no warning; other drivers and an unreadable jobs table give none. `waitingJobsChecks(app, waiting:)`, `embeddedQueueNames(env, queueConfig)`. Guide: [Deployment](docs/guide/deployment.md).

### Upgrade notes

- New public functions `waitingJobsChecks` and `embeddedQueueNames` in `package:dartisan_cli` (an application function of one of these names and the barrel import give an ambiguous-import error; `hide` it or rename yours). `doctor --production` used as a deploy gate now fails while jobs have been waiting over five minutes on the database queue.
