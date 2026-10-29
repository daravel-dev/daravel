import 'dart:io';
import 'dart:typed_data';

/// The 32-byte header of an SQLite write-ahead log
/// (https://www.sqlite.org/fileformat2.html#walformat).
final class WalHeader {
  const WalHeader({
    required this.bigEndianChecksum,
    required this.pageSize,
    required this.checkpointSequence,
    required this.salt1,
    required this.salt2,
    required this.checksum1,
    required this.checksum2,
  });

  static const int size = 32;

  /// The header of [bytes], or `null` when there is none: a missing or
  /// empty log, a wrong magic number or a header checksum that does not
  /// match (a header being written).
  static WalHeader? parse(Uint8List bytes) {
    if (bytes.length < size) {
      return null;
    }
    final data = ByteData.sublistView(bytes, 0, size);
    final magic = data.getUint32(0);
    if (magic != 0x377f0682 && magic != 0x377f0683) {
      return null;
    }
    final bigEndian = magic & 1 == 1;
    final (s1, s2) = walChecksum(bytes, 0, 24, bigEndian, 0, 0);
    if (s1 != data.getUint32(24) || s2 != data.getUint32(28)) {
      return null;
    }
    final pageSize = data.getUint32(8);
    return WalHeader(
      bigEndianChecksum: bigEndian,
      // 1 means 65536 (it does not fit the two-byte field of the database
      // header; the WAL header copies that convention).
      pageSize: pageSize == 1 ? 65536 : pageSize,
      checkpointSequence: data.getUint32(12),
      salt1: data.getUint32(16),
      salt2: data.getUint32(20),
      checksum1: s1,
      checksum2: s2,
    );
  }

  /// Whether frame checksums read the content as big-endian words.
  final bool bigEndianChecksum;
  final int pageSize;

  /// Incremented each time the log restarts from its first frame.
  final int checkpointSequence;

  /// Salt 1 is incremented on each restart and salt 2 drawn at random:
  /// frames left from an earlier pass over the file do not match them.
  final int salt1;
  final int salt2;
  final int checksum1;
  final int checksum2;

  int get frameSize => WalFrame.headerSize + pageSize;

  /// Whether [other] is the same pass over the log file.
  bool sameLog(WalHeader other) => salt1 == other.salt1 && salt2 == other.salt2;
}

/// One frame: a page image and, for the last frame of a transaction, the
/// size of the database after it commits.
final class WalFrame {
  const WalFrame(this.pageNumber, this.commitSize, this.page);

  static const int headerSize = 24;

  final int pageNumber;

  /// The database size in pages after the commit, or 0 when the frame is
  /// not the last of its transaction.
  final int commitSize;
  final Uint8List page;

  bool get isCommit => commitSize != 0;
}

/// The committed frames read from a log, and where reading stopped.
final class WalRead {
  const WalRead({
    required this.frames,
    required this.offset,
    required this.checksum1,
    required this.checksum2,
    required this.validEnd,
  });

  /// The frames of whole transactions, in order, up to the last commit.
  final List<WalFrame> frames;

  /// The byte offset after the last commit frame (where the next read
  /// starts), and the running checksum there.
  final int offset;
  final int checksum1;
  final int checksum2;

  /// Where the valid frames end, committed or not: a later frame has
  /// another salt, a broken checksum, or is not complete.
  final int validEnd;
}

/// Reads the frames of the log in [bytes] that belong to [header], from
/// [offset] with the running checksum ([checksum1], [checksum2]) of the
/// frame before it (the header's for the first frame). Frames are trusted
/// only while their salts match and their cumulative checksum holds,
/// exactly as SQLite decides which frames a reader may use; only frames up
/// to the last commit are returned.
WalRead readWalFrames(
  Uint8List bytes,
  WalHeader header, {
  required int offset,
  required int checksum1,
  required int checksum2,
}) {
  final frames = <WalFrame>[];
  final pending = <WalFrame>[];
  var position = offset;
  var s1 = checksum1, s2 = checksum2;
  var committedAt = offset, c1 = s1, c2 = s2;
  final frameSize = header.frameSize;
  while (position + frameSize <= bytes.length) {
    final data = ByteData.sublistView(bytes, position, position + frameSize);
    if (data.getUint32(8) != header.salt1 ||
        data.getUint32(12) != header.salt2) {
      break;
    }
    var (n1, n2) = walChecksum(
      bytes,
      position,
      position + 8,
      header.bigEndianChecksum,
      s1,
      s2,
    );
    (n1, n2) = walChecksum(
      bytes,
      position + WalFrame.headerSize,
      position + frameSize,
      header.bigEndianChecksum,
      n1,
      n2,
    );
    if (n1 != data.getUint32(16) || n2 != data.getUint32(20)) {
      break;
    }
    s1 = n1;
    s2 = n2;
    final frame = WalFrame(
      data.getUint32(0),
      data.getUint32(4),
      Uint8List.fromList(
        bytes.sublist(position + WalFrame.headerSize, position + frameSize),
      ),
    );
    position += frameSize;
    pending.add(frame);
    if (frame.isCommit) {
      frames.addAll(pending);
      pending.clear();
      committedAt = position;
      c1 = s1;
      c2 = s2;
    }
  }
  return WalRead(
    frames: frames,
    offset: committedAt,
    checksum1: c1,
    checksum2: c2,
    validEnd: position,
  );
}

/// SQLite's WAL checksum over `bytes[start..end)` (a multiple of 8),
/// continuing from ([s1], [s2]): for each pair of 32-bit words x0, x1,
/// `s1 += x0 + s2; s2 += x1 + s1`, modulo 2^32.
(int, int) walChecksum(
  Uint8List bytes,
  int start,
  int end,
  bool bigEndian,
  int s1,
  int s2,
) {
  final data = ByteData.sublistView(bytes, start, end);
  final order = bigEndian ? Endian.big : Endian.little;
  var a = s1, b = s2;
  for (var i = 0; i < end - start; i += 8) {
    a = (a + data.getUint32(i, order) + b) & 0xffffffff;
    b = (b + data.getUint32(i + 4, order) + a) & 0xffffffff;
  }
  return (a, b);
}

/// Writes [frames] into the database file at [path], in order: each page
/// at its place, and the file cut to the commit's size after each commit
/// frame. This is what a checkpoint does. Applying frames a snapshot
/// already contains is harmless: the last image of each page and the last
/// commit's size win.
void applyWalFrames(String path, Iterable<WalFrame> frames, int pageSize) {
  final file = File(path).openSync(mode: FileMode.append);
  try {
    for (final frame in frames) {
      file
        ..setPositionSync((frame.pageNumber - 1) * pageSize)
        ..writeFromSync(frame.page);
      if (frame.isCommit) {
        file.truncateSync(frame.commitSize * pageSize);
      }
    }
    file.flushSync();
  } finally {
    file.closeSync();
  }
}
