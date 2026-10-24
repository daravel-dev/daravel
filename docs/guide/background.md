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

## Scheduling

`routes/console.dart` declares the schedule:

```dart
void consoleRoutes(Schedule schedule) {
  schedule.command('reports:send').dailyAt('13:00').onOneServer();
  schedule.job(const PruneTokens()).hourly().withoutOverlapping();
}
```

Run it with `schedule:work` (long-running) or `schedule:run` from cron;
`schedule:list` shows the next runs.
