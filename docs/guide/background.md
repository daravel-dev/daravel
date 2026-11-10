# Cache, events, queues and scheduling

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#cache-events-queue -->
```dart
final total = await Cache.remember(
  'posts.count',
  const Duration(minutes: 5),
  () => Post.query().count(),
);

await Event.dispatch(const PostPublished(1));
await Queue.dispatch(const PublishPost(1)).onQueue('posts');
```
<!-- /include -->

## Cache

Stores: `memory` (per isolate, LRU), `process` (shared by every isolate of
the server through the coordinator), `file` and `database` (Laravel's
`cache` table). `Cache.remember`, `flexible` (stale-while-revalidate),
`increment`, `pull`, `lock` (atomic locks, fail closed) mirror Laravel.
On the `process` store, a lock the coordinator granted after its answer
timed out is released at once rather than held until its TTL, and
`lock.block` counts such a try as not acquired and tries again.
`Cache.tags(['people', 'artists']).put(...)` tags entries and
`Cache.tags(['people']).flush()` forgets them, on the `memory` and
`process` stores and with [Redis](redis.md#cache-tags), where the keys are
Laravel's; `file` and `database` cannot tag, as in Laravel.

`Cache.flexible` serves the stale value while one background refresh per
key runs. When that refresh fails, the error is logged (the caller already
has its value) and the key is not refreshed again for 5 seconds, so a
failing loader does not run on every request; once the stale window is
over, the value is computed inline and its error reaches the caller.
`Cache.remember` lets one caller compute a missing value: concurrent
misses in one isolate share that computation, and callers elsewhere poll
for the value (every 10 ms at first, up to every 100 ms) until it is
stored or the lock timeout passes.

`Cache.flush()` and `dartisan cache:clear` remove the values but keep the
locks, as Laravel's array and database stores do, so a clear in production
does not hand a held lock to a second holder; `Cache.flushLocks()` and
`cache:clear --locks` release them. The `database` and `file` stores delete
an expired entry when it is read; keys written once and rarely read again
(rate-limit windows, revoked token ids) are deleted by `dartisan
cache:prune-expired [store]` (schedule it hourly), by a lottery on 2 in 100
database writes (as Laravel prunes `cache_locks`) and by a background pass
of the file store at most once an hour.

## Events

`Event.listen<OrderShipped>((event) async {...})` or listener classes in
`bootstrap/listeners.dart`. `Event.dispatchAfterCommit` waits for the
current transaction. Queued listeners run through the queue.

## Queues

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#job -->
```dart
final class PublishPost extends Job {
  const PublishPost(this.postId);

  final int postId;

  @override
  String get jobName => 'publish-post';

  @override
  Map<String, Object?> toJson() => {'post_id': postId};

  @override
  Future<void> handle(JobContext ctx) async {
    final post = await Post.query().findOrFail(postId);
    await post.update({'published': true});
  }
}
```
<!-- /include -->

Jobs are registered by name in `bootstrap/jobs.dart`
(`JobDefinition('publish-post', (json) => PublishPost(...))`), because
Daravel does not use reflection. Drivers: `sync`, `database` (Laravel's
`jobs` / `failed_jobs` tables) and `memory`. Retries, backoff, timeouts,
unique jobs, job middleware, `queue:work`, `queue:failed`, `queue:retry` and
`queue:restart` are supported. Dispatch inside a transaction is deferred
until commit by default.

### Attempts, timeouts and `retry_after`

- `tries` counts every reservation, including a release by middleware
  (`WithoutOverlapping`, `RateLimitedJob`) or `ctx.release()`. A job reserved
  again after its last try fails with `MaxAttemptsExceededException` without
  running, as in Laravel, and so does a job reserved after its `retryUntil`;
  a job released until a lock frees up needs `tries` (or `retryUntil`) that
  cover the wait. `int? get maxExceptions` fails a job after that many
  exceptions, however many tries are left.
- Dart cannot stop a running future, so a handler past its `timeout` keeps
  running. Its `ctx.cancelled` is set, and it runs with `ctx.cancellation` as
  `CancellationToken.current`: a `DB.transaction` it is still in rolls back
  with `OperationCancelledException` instead of committing, and
  `WithoutOverlapping` keeps its lock until `expiresAfter`. A worker whose job
  timed out and was released stops with exit code 1 (`queue:work` ends the
  process), so the process manager starts a fresh one.
- A handler doing long synchronous work (rendering a PDF, encoding a large
  JSON) blocks its isolate: its own timeout cannot fire until it returns.
  Under `daravel_horizon` the master judges a worker that runs a job by that
  job's timeout (the plan's `timeout` when set, otherwise the job's own),
  not by its heartbeats. It kills the worker once the job has run past that
  timeout plus `HORIZON_KILL_GRACE` (10 seconds), or past
  `QUEUE_RETRY_AFTER` if that comes first, since another worker may take
  the job from then on.
  - The killed attempt counts once, and the job is available again at once
    (no backoff). A job with no tries left fails on its next pop with
    `MaxAttemptsExceededException` ("may have previously timed out"), and
    `JobFailed` listeners run.
  - The killed attempt itself dispatches no `JobExceptionOccurred`, and
    `failOnTimeout` does not apply: the job is tried again until its tries
    are used up.
  - `dartisan horizon:list` shows such a worker as busy and "not reporting
    for N s", and lists the attempts killed past their timeout.
  - Only an idle worker that stops answering is killed after three
    heartbeats (its lease). That includes a worker blocked in a job's
    `fromJson`, before the job is reported: the master does not know that
    job yet, so it comes back after `QUEUE_RETRY_AFTER`.
  - Synchronous work that must not keep a worker silent belongs in an
    isolate of its own (`Concurrency.run`).
- An asynchronous error that a handler leaves uncaught (a future it does not
  await) fails the attempt once the handler has returned, never while it
  still runs.
- The database and Redis queues give a reserved job to another worker after
  `QUEUE_RETRY_AFTER` (90 seconds). While a job runs, the worker extends its
  reservation every half `retry_after`, so a long job is not run twice at
  once; the job of a worker that stops responding waits `retry_after`. As in
  Laravel, keep `QUEUE_RETRY_AFTER` above the longest job `timeout`: the
  worker warns when a job's timeout (or `--timeout`) is not below it.
- `Queue.dispatch(job)` pushes the job even when nothing awaits it (in a
  microtask, after the setters chained on it), as Laravel pushes a
  `PendingDispatch` when it goes out of scope. Awaiting it gives the job id
  or the error of the push; a failed push that nothing awaits is logged.

An idle worker waits up to `--sleep` (3 seconds, as Laravel's) between
empty polls, but a push wakes it at once: on PostgreSQL the database queue
sends a `NOTIFY` that every worker on every machine hears, and the memory
queue wakes the workers of its isolate. MySQL and MariaDB workers poll as
Laravel's do.

`queue:work`, `queue:restart` and the server are separate processes, so
what they share lives outside them. With the database queue, unique-job
locks are kept in the `database` cache store (Laravel's `cache_locks`
table), and `queue:restart` / `queue:pause` signals in the `file` store,
which reaches every worker on the machine; `QUEUE_SIGNAL_STORE=database`
reaches workers on every machine.

When the worker's own bookkeeping fails, the job is not lost and the worker
does not stop:

- A `JobProcessing`, `JobProcessed`, `JobExceptionOccurred` or `JobFailed`
  listener that throws is logged; the job is still removed, released or
  recorded as failed, and its unique lock released.
- When the database or the cache fails (a worker started during an outage, a
  signal store on a full disk), the worker logs the first error with its
  stack trace and then at most one a minute, waits longer between polls
  (`--sleep`, doubled after each further error, up to a minute, with
  jitter), and carries on once they are back. A `queue:pause` flag that
  cannot be read counts as not paused. On PostgreSQL a `LISTEN` that cannot
  be opened, or that drops, is opened again 30 seconds later
  (`DatabaseQueue(listenRetry:)`); meanwhile the worker polls.
- A push that fails releases the unique-job lock it took and puts back the
  debounce owner it replaced, so the next dispatch of the unique job is not
  skipped and the debounced dispatch already queued still runs.
- On the Redis queue, as on the database queue, a job whose payload does not
  decode is removed and recorded in `failed_jobs`.
- `serve` refuses `QUEUE_UNIQUE_LOCK_STORE=memory` with several isolates or
  the embedded queue worker: each isolate would keep locks of its own.
- `queue:work --memory=128` stops the worker with exit code 12 once the
  process uses that many megabytes, as Laravel's `--memory` does (no limit
  by default).

For monitoring and operations (the hooks a Horizon-style dashboard builds
on):

- `List<String> get tags` on a job (for example `['user:42']`) is stored in
  the payload's `tags` key.
- `Queue.connection().oldestWait('emails')` says how long the oldest ready
  job has been waiting.
- `dartisan queue:pause database:emails` stops every worker taking jobs from
  that queue (running jobs finish) until `dartisan queue:continue
  database:emails`; `QueueWorker.pause()` / `resume()` do the same for one
  worker.
- `Queue.manager.route<SendEmail>(queue: 'emails')` says where a job type goes,
  in one place. `withoutDelay()` on a dispatch ignores the delay a job declares.
- `bool get deleteWhenMissingModels => true` drops a job whose model is gone. A
  missing model now fails a job at once, as in Laravel, instead of using up its
  tries.
- `Duration? get debounceFor` runs only the last dispatch of a burst with the same
  `debounceId`, that long after it. `debounceMaxWait` lets a long burst through,
  and a job cannot be both debounced and unique.

## Concurrency

`Concurrency.run` runs tasks at once on a pool of warm worker isolates, and
returns the results in order. It is Laravel's `Concurrency` facade, without
starting a process per task.

```dart
final [users, orders] = await Concurrency.run<int>([
  () => countLines(userFile),
  () => countLines(orderFile),
], timeout: const Duration(seconds: 30));
```

Every task runs. Then the first failure, by position, is rethrown with its stack
trace. A task past `timeout` fails with a `TimeoutException`. `concurrency` caps
a run, and `Concurrency.maxWorkers` caps the pool, by default the smaller of the
processor count and 4. With `serve --isolates=N`, each isolate has its own pool.
The timeout starts when a task is handed to the pool, so it also bounds the
wait for a worker that other callers keep busy. `Concurrency.maxQueue` (no
limit by default) caps the tasks waiting for a worker; past it a task fails at
once with a `StateError` instead of queueing.

A task runs in another isolate, and this is where it differs from Laravel, whose
tasks boot the application:

- Facades do not work there. Pass the values a task needs, and return a result.
- A closure sends all it captures, and closures in an async function capture its
  whole scope. A `Request` or a socket in scope fails with an `ArgumentError`, so
  build tasks in a small function, or use static ones.

`Concurrency.defer` runs tasks on the workers after the response is sent, and logs
failures. For deferred work that needs facades, use `Request.defer`.

`Concurrency.runIfLarge(payloadBytes, task)` runs small work here, where crossing
to a worker costs more than it saves, and large work on a worker.

In tests, `Concurrency.sync(body)` runs tasks one by one in this isolate, and
`Concurrency.fake((fake) async { … })` also counts them with `assertRanCount` and
`assertDeferredCount`.

### Binary results

`Concurrency.runBytes` is `run` for tasks that return a `Uint8List`: a PDF, a
CSV, an image, a compressed body. A result of 32 KB or more comes back as a
`TransferableTypedData`, copied once in the worker and moved to the caller
without a second copy. `Response.computed` sends it as the body, also without a
copy:

```dart
final [pdf] = await Concurrency.runBytes([() => renderInvoice(data)]);
return Response.computed(pdf, contentType: 'application/pdf');
```

Return text, JSON included, from `run` as a `String`: the VM shares a string
between isolates instead of copying it, which beats any byte transfer.
`IsolatePayload.text` and `IsolatePayload.bytes` apply the same rule to your own
`SendPort`s: send `toWire()`, and call `IsolatePayload.fromWire` once, in the
receiving port's handler. A transferable can be received only once, so a message
sent to many ports stays a `String`.

## Context

Laravel 11's `Context` holds data about the current request, job or
command. Visible entries are added to every log record, and everything,
hidden entries included, travels with the jobs dispatched from there:

```dart
// A middleware
Context.add('tenant_id', tenant.id);
Context.addHidden('api_token', token);    // carried, never logged

// Later in the request, or inside the queued job minutes later
final tenantId = Context.get<int>('tenant_id');
```

`addMany`, `addIf`, `push(key, [values])`, `has`, `forget`, `all()` and
the `…Hidden` counterparts complete it. Each request starts empty. Values
must be JSON-encodable, like job data, and hidden values are stored in the
job payload (the `jobs` table), so keep real secrets out of it.

## Scheduling

`routes/console.dart` declares the schedule:

```dart
void consoleRoutes(Schedule schedule) {
  schedule.command('reports:send').dailyAt('13:00').onOneServer();
  schedule.job(const PruneTokens()).hourly().withoutOverlapping();
}
```

Run it with `schedule:work` (long-running) or `schedule:run` from cron;
`schedule:list` shows the next runs and each task's zone.

On `SIGTERM`, `schedule:work` (and the embedded scheduler) starts nothing
new and waits for the tasks under way, background ones included, for up to
30 seconds (`Scheduler.stop(drain:)`; the embedded scheduler takes three
quarters of the shutdown timeout). A task still running then has its
`withoutOverlapping` lock released and ends with the process, instead of
keeping the next runs away until the lock expires;
`dartisan schedule:clear-cache` releases the overlap locks that a killed
scheduler left behind. A task whose filter (`when`, `skip`), lock or event
listener throws is logged and skipped (`ScheduledTaskSkipped` with reason
`error`), and the other tasks of the minute still run. As in Laravel,
`onOneServer` locks name the task's expression and name and the minute the
run started, so a slow task before it cannot carry it into the next minute
on one server; unnamed jobs of one class are told apart by their data, and
an unnamed closure needs `named(...)`.

Cron expressions are read in `SCHEDULE_TIMEZONE` (Laravel's
`app.schedule_timezone`), or in UTC when it is not set, unless a task names
its own zone. Laravel falls back to `APP_TIMEZONE`; Daravel 1.x does not, so
upgrading never moves existing schedules, and `dartisan doctor` warns when
`APP_TIMEZONE` is not UTC while `SCHEDULE_TIMEZONE` is empty.
`schedule:list --timezone=Asia/Jakarta` shows the next runs in that zone.

```dart
schedule.command('reports:send').dailyAt('08:00').timezone('Asia/Jakarta');
schedule.job(const Digest()).dailyAt('09:00').timezone('America/New_York');
schedule.call(sync).hourly().timezone(const Duration(hours: 7)); // fixed offset
```

IANA zones follow daylight saving time as Laravel does: a time skipped when
the clocks go forward runs that much later (02:30 runs at 03:30), and a time
repeated when they go back runs twice. (This assumes clock changes of at
most 3 hours, more than 3 hours apart, as in every current DST rule; a
one-off change such as Samoa's 24-hour jump in 2011 could misfire once.)
The zone database is compiled into
the binary (about 0.5 MB, with the alias names PHP accepts: `UTC`, `GMT`,
`US/Eastern`, ...); an unknown zone name throws at boot, and `dartisan lint`
reports it (`invalid_timezone`).

## Laravel equivalents

More of Laravel that this works with, and the API to look up on pub.dev.

| Laravel | Daravel | API | Note |
| :-- | :-- | :-- | :-- |
| `Cache::flexible($key, [$fresh, $stale], fn)` | `await Cache.flexible(...)` | `Cache.flexible` |  |
| `SendEmail::dispatch()->withoutDelay()` | `.withoutDelay()` | `PendingDispatch.withoutDelay` |  |
| `public $deleteWhenMissingModels = true` | `bool get deleteWhenMissingModels => true` | `Job.deleteWhenMissingModels` |  |
| `#[DebounceFor(60)]` | `Duration? get debounceFor => ...` | `Job.debounceFor` |  |
| `(new WithoutOverlapping($key))->shared()` | `WithoutOverlapping(key, shared: true)` | `WithoutOverlapping.shared` |  |
