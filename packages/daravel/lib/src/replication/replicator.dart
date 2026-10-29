import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../foundation/exceptions.dart';
import '../storage/storage.dart';
import 'wal.dart';

/// Thrown when a database cannot be replicated or restored.
final class ReplicationException extends DaravelException {
  const ReplicationException(super.message);
}

/// The layout of a replica on a disk, under its prefix:
///
/// ```text
/// generations/<generation>/snapshot-<ms>.db.gz        page copy of the database
/// generations/<generation>/wal/<index>-<ms>.wal.gz    committed frames after it
/// ```
///
/// A generation starts with a snapshot; its segments, applied in order,
/// bring the snapshot forward. Generation names sort by time.
abstract final class ReplicaLayout {
  static String generations(String prefix) => _join(prefix, 'generations');

  static String generation(String prefix, String id) =>
      _join(generations(prefix), id);

  static String snapshot(String prefix, String id, int ms) =>
      '${generation(prefix, id)}/snapshot-$ms.db.gz';

  static String segment(String prefix, String id, int index, int ms) =>
      '${generation(prefix, id)}/wal/${'$index'.padLeft(10, '0')}-$ms.wal.gz';

  static String _join(String a, String b) => a.isEmpty
      ? b
      : '${a.endsWith('/') ? a.substring(0, a.length - 1) : a}/$b';

  /// A new generation name: UTC time to the millisecond, then random, so
  /// names sort by time (`20261029T101500123Z-1f2e3d4c`). The caller keeps
  /// [now] increasing: a restore takes the last name as the newest.
  static String newGeneration(DateTime now) {
    final t = now.toUtc().toIso8601String().replaceAll(RegExp(r'[-:.]'), '');
    final stamp = t.substring(0, 18); // 20261029T101500123
    final random = math.Random.secure().nextInt(1 << 32).toRadixString(16);
    return '${stamp}Z-${random.padLeft(8, '0')}';
  }
}

/// Encodes frames as a segment: `DRVWAL01`, page size, frame count, then
/// per frame its page number, commit size and page.
Uint8List encodeSegment(List<WalFrame> frames, int pageSize) {
  final out = BytesBuilder(copy: false)
    ..add('DRVWAL01'.codeUnits)
    ..add(_u32(pageSize))
    ..add(_u32(frames.length));
  for (final frame in frames) {
    out
      ..add(_u32(frame.pageNumber))
      ..add(_u32(frame.commitSize))
      ..add(frame.page);
  }
  return gzip.encode(out.takeBytes()) as Uint8List;
}

/// The page size and frames of a segment written by [encodeSegment].
(int, List<WalFrame>) decodeSegment(List<int> compressed) {
  final bytes = Uint8List.fromList(gzip.decode(compressed));
  if (bytes.length < 16 ||
      String.fromCharCodes(bytes.sublist(0, 8)) != 'DRVWAL01') {
    throw const ReplicationException('Not a WAL segment.');
  }
  final data = ByteData.sublistView(bytes);
  final pageSize = data.getUint32(8);
  final count = data.getUint32(12);
  final frames = <WalFrame>[];
  var at = 16;
  for (var i = 0; i < count; i++) {
    if (at + 8 + pageSize > bytes.length) {
      throw const ReplicationException('Truncated WAL segment.');
    }
    frames.add(
      WalFrame(
        data.getUint32(at),
        data.getUint32(at + 4),
        Uint8List.sublistView(bytes, at + 8, at + 8 + pageSize),
      ),
    );
    at += 8 + pageSize;
  }
  return (pageSize, frames);
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

/// What one [SqliteReplicator.sync] did.
final class ReplicationSync {
  const ReplicationSync({
    required this.generation,
    required this.frames,
    required this.newGeneration,
    this.reason,
  });

  final String generation;

  /// Committed frames shipped by this sync.
  final int frames;

  /// Whether this sync started a generation (a new snapshot).
  final bool newGeneration;

  /// Why it did: `start`, `snapshot interval`, or the discontinuity found.
  final String? reason;
}

/// Ships an SQLite database in WAL mode to a [Disk], as Litestream does
/// (Blueprint #30): a page-exact snapshot, then the committed frames of
/// the write-ahead log as they appear, so a restore loses at most what
/// was committed since the last [sync].
///
/// Two rules keep a replica correct whatever the application and SQLite
/// do meanwhile:
///
/// - Only frames SQLite itself would trust are shipped: the salts of the
///   current log, an unbroken cumulative checksum, and whole committed
///   transactions.
/// - When the log was restarted or truncated and the replicator cannot
///   prove it read every frame of the old one, it starts a generation: a
///   new snapshot, through SQLite's backup API (page-exact, so the log's
///   frames still apply), taken between two reads of the log header that
///   find the same log.
///
/// Between syncs it holds a read transaction, which stops SQLite from
/// restarting the log under it; when the log grows past
/// [checkpointPages], it checkpoints (RESTART) right after catching up,
/// and the next sync reads the few frames written in between from the old
/// log's tail. A database that has no log yet gets one write into the
/// `_daravel_replication` table, as Litestream does with its own table.
final class SqliteReplicator {
  SqliteReplicator(
    this.databasePath,
    this.disk, {
    this.prefix = '',
    this.checkpointPages = 1000,
    this.snapshotInterval = const Duration(hours: 24),
    this.retain = 2,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String databasePath;
  final Disk disk;

  /// Where on [disk] the replica lives.
  final String prefix;

  /// Log size (in frames) after which the replicator checkpoints.
  final int checkpointPages;

  /// A generation older than this is replaced by a fresh snapshot, which
  /// bounds how many segments a restore applies.
  final Duration snapshotInterval;

  /// Generations kept on the disk, the current one included.
  final int retain;

  final DateTime Function() _clock;

  Database? _db;
  String? _generation;
  DateTime? _generationStarted;
  WalHeader? _header;
  int _offset = WalHeader.size;
  int _checksum1 = 0;
  int _checksum2 = 0;
  int _index = 0;
  bool _reading = false;

  String get _walPath => '$databasePath-wal';

  /// The current generation, once the first sync started one.
  String? get generation => _generation;

  /// Ships what was committed since the last call; starts a generation
  /// when needed. Not reentrant: run syncs one after the other.
  Future<ReplicationSync> sync() async {
    final db = _open();
    if (_generation == null) {
      return _startGeneration(db, 'start');
    }
    final started = _generationStarted!;
    if (_clock().difference(started) >= snapshotInterval) {
      return _startGeneration(db, 'snapshot interval');
    }
    _endRead(db);
    try {
      final bytes = _readWal();
      final header = WalHeader.parse(bytes);
      final current = _header!;
      if (header == null) {
        return await _startGeneration(db, 'log truncated');
      }
      var shipped = 0;
      if (!header.sameLog(current)) {
        final tail = await _shipOldTail(bytes, header, current);
        if (tail == null) {
          return await _startGeneration(db, 'log restarted');
        }
        shipped += tail;
        _header = header;
        _offset = WalHeader.size;
        _checksum1 = header.checksum1;
        _checksum2 = header.checksum2;
      }
      shipped += await _ship(bytes, _header!);
      if (_offset ~/ _header!.frameSize >= checkpointPages) {
        shipped += await _rollOver(db);
      }
      return ReplicationSync(
        generation: _generation!,
        frames: shipped,
        newGeneration: false,
      );
    } finally {
      _beginRead(db);
    }
  }

  /// Syncs every [interval] until [stop]. Errors go to [onError] and the
  /// next tick tries again (frames not shipped stay in the log).
  Timer start({
    Duration interval = const Duration(seconds: 1),
    void Function(ReplicationSync sync)? onSync,
    void Function(Object error, StackTrace stack)? onError,
  }) {
    var running = false;
    return Timer.periodic(interval, (_) async {
      if (running) {
        return;
      }
      running = true;
      try {
        final result = await sync();
        onSync?.call(result);
      } on Object catch (error, stack) {
        onError?.call(error, stack);
      } finally {
        running = false;
      }
    });
  }

  /// Releases the database.
  void close() {
    final db = _db;
    if (db != null) {
      _endRead(db);
      db.close();
      _db = null;
    }
  }

  Database _open() {
    final existing = _db;
    if (existing != null) {
      return existing;
    }
    if (!File(databasePath).existsSync()) {
      throw ReplicationException('No database at $databasePath.');
    }
    final db = sqlite3.open(databasePath)
      ..execute('PRAGMA busy_timeout = 5000');
    final mode = db.select('PRAGMA journal_mode').first.values.first;
    if (mode != 'wal') {
      db.close();
      throw ReplicationException(
        'Replication needs WAL mode; $databasePath is in "$mode" mode.',
      );
    }
    return _db = db;
  }

  void _beginRead(Database db) {
    if (!_reading) {
      db
        ..execute('BEGIN')
        ..select('SELECT count(*) FROM sqlite_master');
      _reading = true;
    }
  }

  void _endRead(Database db) {
    if (_reading) {
      db.execute('COMMIT');
      _reading = false;
    }
  }

  Uint8List _readWal() {
    final file = File(_walPath);
    return file.existsSync() ? file.readAsBytesSync() : Uint8List(0);
  }

  /// Ships the committed frames of [header]'s log after [_offset].
  Future<int> _ship(Uint8List bytes, WalHeader header) async {
    final read = readWalFrames(
      bytes,
      header,
      offset: _offset,
      checksum1: _checksum1,
      checksum2: _checksum2,
    );
    if (read.frames.isNotEmpty) {
      await _upload(read.frames, header.pageSize);
    }
    _offset = read.offset;
    _checksum1 = read.checksum1;
    _checksum2 = read.checksum2;
    return read.frames.length;
  }

  /// Folds the log into the database and has it start over at a moment
  /// this replicator controls, as Litestream does: checkpoint, then under
  /// the write lock ship what is left of the old log and write a marker
  /// with a random token. When that write restarts the log, no other
  /// writer can have added to the old log after the read (the lock), so
  /// following the new log from its first frame loses nothing. The token,
  /// found in the new log's first transaction, proves the restart was
  /// this write and not a later one.
  Future<int> _rollOver(Database db) async {
    final old = _header!;
    final result = db.select('PRAGMA wal_checkpoint(RESTART)').first.values;
    if (result.first != 0) {
      return 0; // A reader kept it from finishing; try next time.
    }
    final token = List<int>.generate(
      16,
      (_) => math.Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    var shipped = 0;
    db.execute('BEGIN IMMEDIATE');
    try {
      final bytes = _readWal();
      final header = WalHeader.parse(bytes);
      if (header == null || !header.sameLog(old)) {
        // Someone restarted it first: the next sync follows that.
        db.execute('ROLLBACK');
        return 0;
      }
      shipped = await _ship(bytes, header);
      _ensureMarkerTable(db);
      db
        ..execute(
          'INSERT OR REPLACE INTO _daravel_replication VALUES (1, ?, ?)',
          ['restart $token', _clock().millisecondsSinceEpoch],
        )
        ..execute('COMMIT');
    } on Object {
      if (!db.autocommit) {
        db.execute('ROLLBACK');
      }
      rethrow;
    }
    final bytes = _readWal();
    final header = WalHeader.parse(bytes);
    if (header == null || header.sameLog(old)) {
      return shipped; // Not restarted (a reader): the old log goes on.
    }
    final first = readWalFrames(
      bytes,
      header,
      offset: WalHeader.size,
      checksum1: header.checksum1,
      checksum2: header.checksum2,
    );
    final firstCommit = first.frames.indexWhere((f) => f.isCommit);
    final ours =
        firstCommit >= 0 &&
        first.frames
            .take(firstCommit + 1)
            .any((f) => _contains(f.page, 'restart $token'.codeUnits));
    if (ours) {
      _header = header;
      _offset = WalHeader.size;
      _checksum1 = header.checksum1;
      _checksum2 = header.checksum2;
    }
    return shipped;
  }

  static bool _contains(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          continue outer;
        }
      }
      return true;
    }
    return false;
  }

  void _ensureMarkerTable(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS _daravel_replication '
    '(id INTEGER PRIMARY KEY, generation TEXT, at INTEGER)',
  );

  /// After one restart, the frames the old log got after [_offset] are
  /// still in the file past the new log's end. Ships them and returns how
  /// many, or `null` when that cannot be proven: more than one restart, or
  /// the new log already reaches [_offset].
  Future<int?> _shipOldTail(
    Uint8List bytes,
    WalHeader header,
    WalHeader old,
  ) async {
    final oneRestart =
        header.salt1 == ((old.salt1 + 1) & 0xffffffff) &&
        header.checkpointSequence ==
            ((old.checkpointSequence + 1) & 0xffffffff) &&
        header.pageSize == old.pageSize;
    if (!oneRestart) {
      return null;
    }
    bool clear(Uint8List snapshot) {
      final now = WalHeader.parse(snapshot);
      if (now == null || !now.sameLog(header)) {
        return false;
      }
      final newLog = readWalFrames(
        snapshot,
        now,
        offset: WalHeader.size,
        checksum1: now.checksum1,
        checksum2: now.checksum2,
      );
      return newLog.validEnd <= _offset;
    }

    if (!clear(bytes)) {
      return null;
    }
    final tail = readWalFrames(
      bytes,
      old,
      offset: _offset,
      checksum1: _checksum1,
      checksum2: _checksum2,
    );
    // Read again: the new log must still end before the tail, so the
    // first read cannot have caught a half-overwritten tail.
    if (!clear(_readWal())) {
      return null;
    }
    if (tail.frames.isNotEmpty) {
      await _upload(tail.frames, old.pageSize);
    }
    return tail.frames.length;
  }

  Future<void> _upload(List<WalFrame> frames, int pageSize) async {
    final ms = _clock().millisecondsSinceEpoch;
    await disk.put(
      ReplicaLayout.segment(prefix, _generation!, _index, ms),
      encodeSegment(frames, pageSize),
    );
    _index++;
  }

  Future<ReplicationSync> _startGeneration(Database db, String reason) async {
    _endRead(db);
    try {
      for (var attempt = 0; attempt < 10; attempt++) {
        var before = WalHeader.parse(_readWal());
        if (before == null) {
          // Give the database a log to follow.
          _ensureMarkerTable(db);
          db.execute(
            'INSERT OR REPLACE INTO _daravel_replication VALUES (1, ?, ?)',
            [reason, _clock().millisecondsSinceEpoch],
          );
          before = WalHeader.parse(_readWal());
          if (before == null) {
            continue;
          }
        }
        final snapshot = await _snapshot(db);
        final after = WalHeader.parse(_readWal());
        if (after == null || !after.sameLog(before)) {
          // Restarted while copying: the copy may miss frames of the old
          // log that are not in the new one. Copy again.
          continue;
        }
        // Strictly after the previous generation, even within a
        // millisecond or with a clock that went back.
        var started = _clock();
        final previous = _generationStarted;
        if (previous != null && !started.isAfter(previous)) {
          started = previous.add(const Duration(milliseconds: 1));
        }
        final id = ReplicaLayout.newGeneration(started);
        final ms = _clock().millisecondsSinceEpoch;
        await disk.put(ReplicaLayout.snapshot(prefix, id, ms), snapshot);
        _generation = id;
        _generationStarted = started;
        _header = before;
        // The snapshot may already contain some of these frames; applying
        // them again changes nothing.
        _offset = WalHeader.size;
        _checksum1 = before.checksum1;
        _checksum2 = before.checksum2;
        _index = 0;
        final shipped = await _ship(_readWal(), before);
        await _prune();
        return ReplicationSync(
          generation: id,
          frames: shipped,
          newGeneration: true,
          reason: reason,
        );
      }
      throw const ReplicationException(
        'The log restarted during every snapshot attempt.',
      );
    } finally {
      _beginRead(db);
    }
  }

  /// A page-exact copy of the database (SQLite's backup API, one step:
  /// one read transaction), gzipped.
  Future<Uint8List> _snapshot(Database db) async {
    final temp = Directory.systemTemp.createTempSync('daravel_snapshot_');
    try {
      final path = '${temp.path}${Platform.pathSeparator}snapshot.db';
      final target = sqlite3.open(path);
      try {
        await db.backup(target, nPage: -1).drain<void>();
      } finally {
        target.close();
      }
      return gzip.encode(File(path).readAsBytesSync()) as Uint8List;
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  Future<void> _prune() async {
    final all = await listReplicaGenerations(disk, prefix);
    for (final old in all.take(math.max(0, all.length - retain))) {
      await disk.deleteDirectory(ReplicaLayout.generation(prefix, old));
    }
  }
}

/// The generations of the replica under [prefix], oldest first.
Future<List<String>> listReplicaGenerations(Disk disk, String prefix) async {
  final root = ReplicaLayout.generations(prefix);
  // No exists(): directories are only prefixes on object stores.
  final names = [
    for (final directory in await disk.directories(root))
      directory.split('/').last,
  ]..sort();
  return names;
}

/// What a restore applied.
final class ReplicaRestore {
  const ReplicaRestore({
    required this.generation,
    required this.segments,
    required this.frames,
  });

  final String generation;
  final int segments;
  final int frames;
}

/// Restores the replica under [prefix] to [target]: the snapshot of the
/// newest generation (or [generation]), then its segments in order, up to
/// [at] when given (point in time; the generation is then the newest one
/// whose snapshot is not after it). Refuses to overwrite a file unless
/// [overwrite]. Checks the result with `PRAGMA integrity_check`.
Future<ReplicaRestore> restoreReplica(
  Disk disk,
  String prefix,
  String target, {
  String? generation,
  DateTime? at,
  bool overwrite = false,
}) async {
  if (File(target).existsSync() && !overwrite) {
    throw ReplicationException('$target exists; pass overwrite to replace it.');
  }
  final limit = at?.millisecondsSinceEpoch;
  int stamp(String path) {
    final name = path.split('/').last;
    return int.parse(RegExp(r'(\d+)\.(db|wal)\.gz$').firstMatch(name)![1]!);
  }

  String? chosen = generation;
  String? snapshotPath;
  final candidates = generation != null
      ? [generation]
      : (await listReplicaGenerations(disk, prefix)).reversed.toList();
  for (final id in candidates) {
    final files = await disk.files(ReplicaLayout.generation(prefix, id));
    final snapshots = files.where(
      (f) => f.split('/').last.startsWith('snapshot-'),
    );
    final usable = [
      for (final s in snapshots)
        if (limit == null || stamp(s) <= limit) s,
    ];
    if (usable.isNotEmpty) {
      chosen = id;
      snapshotPath = usable.first;
      break;
    }
  }
  if (chosen == null || snapshotPath == null) {
    throw const ReplicationException('No snapshot to restore from.');
  }
  final temp = '$target.restoring';
  for (final leftover in [temp, '$temp-wal', '$temp-shm']) {
    if (File(leftover).existsSync()) {
      File(leftover).deleteSync();
    }
  }
  File(temp).writeAsBytesSync(gzip.decode(await disk.getBytes(snapshotPath)));
  final segments = [
    for (final file in await disk.files(
      '${ReplicaLayout.generation(prefix, chosen)}/wal',
    ))
      if (limit == null || stamp(file) <= limit) file,
  ]..sort();
  var frames = 0;
  for (final segment in segments) {
    final (pageSize, decoded) = decodeSegment(await disk.getBytes(segment));
    applyWalFrames(temp, decoded, pageSize);
    frames += decoded.length;
  }
  final check = sqlite3.open(temp);
  try {
    final result = check.select('PRAGMA integrity_check').first.values.first;
    if (result != 'ok') {
      throw ReplicationException('The restored database is damaged: $result');
    }
  } finally {
    check.close();
  }
  for (final stale in ['$target-wal', '$target-shm']) {
    if (File(stale).existsSync()) {
      File(stale).deleteSync();
    }
  }
  File(temp).renameSync(target);
  return ReplicaRestore(
    generation: chosen,
    segments: segments.length,
    frames: frames,
  );
}
