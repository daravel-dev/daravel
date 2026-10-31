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
`Cache.tags(['people', 'artists']).put(...)` tags entries and
`Cache.tags(['people']).flush()` forgets them, on the `memory` and
`process` stores and with [Redis](redis.md#cache-tags), where the keys are
Laravel's; `file` and `database` cannot tag, as in Laravel.

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
