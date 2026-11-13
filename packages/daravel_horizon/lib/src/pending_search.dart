import 'package:daravel/daravel.dart';

/// What [findPending] found: the job (null when not found), how many
/// views it read, and whether it read to the end of the queue (false when
/// it stopped at its limit).
typedef PendingSearch = ({QueuedJobView? job, int read, bool exhausted});

/// The pending job [id] of [queue], read [page] jobs at a time.
///
/// Workers keep popping from the head while it reads, which moves every
/// job towards the start: each page starts [overlap] jobs before the end
/// of the last one, so a job is missed only when more than [overlap] jobs
/// are popped between two pages. It stops after [limit] views read.
Future<PendingSearch> findPending(
  BrowsableQueueDriver driver,
  String queue,
  String id, {
  int page = 1000,
  int overlap = 250,
  int limit = 100000,
}) async {
  assert(overlap < page, 'each page must move forward');
  var offset = 0;
  var read = 0;
  while (read < limit) {
    final views = await driver.pending(queue, limit: page, offset: offset);
    read += views.length;
    for (final view in views) {
      if ('${view.id}' == id) {
        return (job: view, read: read, exhausted: false);
      }
    }
    if (views.length < page) {
      return (job: null, read: read, exhausted: true);
    }
    offset += page - overlap;
  }
  return (job: null, read: read, exhausted: false);
}
