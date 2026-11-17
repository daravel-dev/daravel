import 'package:meta/meta.dart';

/// What the WebSocket connections of this isolate hold now, and the most
/// they held since [reset]:
/// - the bytes of the fragmented messages being assembled;
/// - what is held for handlers that do not read (bytes and a cost per
///   item) and its items;
/// - what waits to be written below the WebSocket (PONGs included);
/// - what waits in the applications' send queues (`BufferedWebSocket`);
/// - the rest of a chunk read from a client and not parsed yet, and the
///   largest chunk read.
///
/// For tests, which read these counts instead of the process's resident
/// memory: [assemblingBy] and the others are called by the guard and the
/// socket as their counts change, integers only. A candidate for the
/// `daravel_websocket_*` metrics, whose shape (per isolate or process, per
/// route, who resets the peaks) is to be decided with them. Not exported.
abstract final class WebSocketGuardStats {
  static int _assembling = 0;
  static int _assemblingPeak = 0;
  static int _held = 0;
  static int _heldPeak = 0;
  static int _heldItems = 0;
  static int _heldItemsPeak = 0;
  static int _waiting = 0;
  static int _waitingPeak = 0;
  static int _queued = 0;
  static int _queuedPeak = 0;
  static int _unparsed = 0;
  static int _unparsedPeak = 0;
  static int _chunkPeak = 0;
  static int _chunksWhileUnparsed = 0;

  /// Peaks back to the current counts (the largest chunk and the chunks
  /// read while a rest waited to none).
  @visibleForTesting
  static void reset() {
    _assemblingPeak = _assembling;
    _heldPeak = _held;
    _heldItemsPeak = _heldItems;
    _waitingPeak = _waiting;
    _queuedPeak = _queued;
    _unparsedPeak = _unparsed;
    _chunkPeak = 0;
    _chunksWhileUnparsed = 0;
  }

  /// Every count and peak, by name.
  @visibleForTesting
  static Map<String, int> toJson() => {
    'assembling': _assembling,
    'assemblingPeak': _assemblingPeak,
    'held': _held,
    'heldPeak': _heldPeak,
    'heldItems': _heldItems,
    'heldItemsPeak': _heldItemsPeak,
    'waiting': _waiting,
    'waitingPeak': _waitingPeak,
    'queued': _queued,
    'queuedPeak': _queuedPeak,
    'unparsed': _unparsed,
    'unparsedPeak': _unparsedPeak,
    'chunkPeak': _chunkPeak,
    'chunksWhileUnparsed': _chunksWhileUnparsed,
  };

  /// The rest of a chunk kept unparsed changed by [delta].
  static void unparsedBy(int delta) {
    _unparsed += delta;
    if (_unparsed > _unparsedPeak) {
      _unparsedPeak = _unparsed;
    }
  }

  /// A chunk of [length] bytes was read from a client.
  static void chunkRead(int length) {
    if (length > _chunkPeak) {
      _chunkPeak = length;
    }
  }

  /// A chunk was read while the rest of an earlier one waited unparsed,
  /// which pausing the reading is to prevent: tests expect none.
  static void chunkWhileUnparsed() {
    _chunksWhileUnparsed++;
  }

  /// The bytes being assembled changed by [delta].
  static void assemblingBy(int delta) {
    _assembling += delta;
    if (_assembling > _assemblingPeak) {
      _assemblingPeak = _assembling;
    }
  }

  /// What is held changed by [delta].
  static void heldBy(int delta) {
    _held += delta;
    if (_held > _heldPeak) {
      _heldPeak = _held;
    }
  }

  /// The items held changed by [delta].
  static void heldItemsBy(int delta) {
    _heldItems += delta;
    if (_heldItems > _heldItemsPeak) {
      _heldItemsPeak = _heldItems;
    }
  }

  /// What waits to be written changed by [delta].
  static void waitingBy(int delta) {
    _waiting += delta;
    if (_waiting > _waitingPeak) {
      _waitingPeak = _waiting;
    }
  }

  /// What waits in a send queue changed by [delta].
  static void queuedBy(int delta) {
    _queued += delta;
    if (_queued > _queuedPeak) {
      _queuedPeak = _queued;
    }
  }
}
