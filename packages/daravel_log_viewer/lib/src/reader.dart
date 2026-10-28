import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'entry.dart';

/// Which entries a page keeps.
final class LogFilter {
  const LogFilter({this.levels = const {}, this.search});

  /// Levels to keep (`error`, `warning`, ...); all when empty.
  final Set<String> levels;

  /// Text the entry must contain, ignoring case.
  final String? search;

  /// A cheap test on the entry's text before it is parsed: false only
  /// when the entry cannot match (the search text or every wanted level
  /// name is missing from it).
  bool mayMatch(String text) {
    final lower = text.toLowerCase();
    final wanted = search;
    if (wanted != null &&
        wanted.isNotEmpty &&
        !lower.contains(wanted.toLowerCase())) {
      return false;
    }
    return levels.isEmpty || levels.any(lower.contains);
  }

  bool matches(LogEntry entry) {
    if (levels.isNotEmpty && !levels.contains(entry.level)) {
      return false;
    }
    final text = search;
    return text == null ||
        text.isEmpty ||
        entry.raw.toLowerCase().contains(text.toLowerCase());
  }
}

/// A page of entries, newest first, and where the next (older) page
/// starts.
final class LogPage {
  const LogPage(this.entries, this.next, this.scannedBytes);

  final List<LogEntry> entries;

  /// The byte offset to pass as `before` for older entries; `null` at the
  /// start of the file.
  final int? next;

  /// How much of the file this page read.
  final int scannedBytes;
}

/// Reads a log file from its end, a block at a time, so the newest
/// entries of a file of any size come back in constant memory and time.
final class ReverseLogReader {
  ReverseLogReader(this.path, {this.blockSize = 64 * 1024});

  final String path;
  final int blockSize;

  /// A line longer than this is cut, so one runaway line cannot hold a
  /// file's worth of bytes in memory.
  static const int maxLineBytes = 4 * 1024 * 1024;

  /// Up to [limit] entries matching [filter], newest first, from those
  /// that end before [before] (the file's end when null). Stops after
  /// reading [maxScanBytes], returning what it found and where to go on.
  Future<LogPage> page({
    int? before,
    int limit = 50,
    LogFilter filter = const LogFilter(),
    int maxScanBytes = 64 * 1024 * 1024,
  }) async {
    final file = await File(path).open();
    try {
      final length = await file.length();
      var position = math.min(before ?? length, length);
      final start = position;
      final entries = <LogEntry>[];
      // Lines below the one being read that continue an entry above them
      // (a Monolog stack trace), newest last.
      final pending = <(int, Uint8List)>[];
      // The start of the line that continues into the block read next.
      var carry = Uint8List(0);
      int? next = position == 0 ? null : position;

      bool emit(int offset, Uint8List firstLine) {
        final parts = [
          firstLine,
          for (final (_, line) in pending.reversed) line,
        ];
        final end = pending.isEmpty
            ? offset + firstLine.length + 1
            : pending.first.$1 + pending.first.$2.length + 1;
        pending.clear();
        final text = parts
            .map((bytes) => utf8.decode(bytes, allowMalformed: true))
            .join('\n');
        if (filter.mayMatch(text)) {
          final entry = LogEntry.parse(text, offset, end - offset);
          if (filter.matches(entry)) {
            entries.add(entry);
          }
        }
        next = offset == 0 ? null : offset;
        return entries.length >= limit || start - offset >= maxScanBytes;
      }

      /// Handles the line at [offset]; true when the page is full.
      bool line(int offset, Uint8List bytes) {
        if (bytes.isNotEmpty && bytes.last == 0x0D) {
          bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
        }
        if (bytes.length > maxLineBytes) {
          bytes = Uint8List.sublistView(bytes, 0, maxLineBytes);
        }
        if (bytes.isEmpty && pending.isEmpty) {
          return false;
        }
        final probe = utf8.decode(
          bytes.length > 64 ? Uint8List.sublistView(bytes, 0, 64) : bytes,
          allowMalformed: true,
        );
        if (LogEntry.startsEntry(probe)) {
          return emit(offset, bytes);
        }
        pending.add((offset, bytes));
        return false;
      }

      while (position > 0) {
        final from = math.max(0, position - blockSize);
        await file.setPosition(from);
        final block = await file.read(position - from);
        final data = carry.isEmpty
            ? block
            : (BytesBuilder(copy: false)
                    ..add(block)
                    ..add(carry))
                  .takeBytes();
        position = from;
        // Lines from the last to the first; the first one may begin in the
        // block before, so it waits for it.
        var end = data.length;
        for (var i = end - 1; i >= 0; i--) {
          if (data[i] != 0x0A) {
            continue;
          }
          if (line(from + i + 1, Uint8List.sublistView(data, i + 1, end))) {
            return LogPage(entries, next, start - (next ?? 0));
          }
          end = i;
        }
        carry = Uint8List.fromList(Uint8List.sublistView(data, 0, end));
        if (carry.length > maxLineBytes && position > 0) {
          // A line longer than the limit: kept from its end.
          carry = Uint8List.sublistView(carry, carry.length - maxLineBytes);
        }
      }
      // The file's first line.
      if (carry.isNotEmpty || pending.isNotEmpty) {
        line(0, carry);
        if (pending.isNotEmpty) {
          // Continuation lines with no entry above them: one text entry.
          final (offset, first) = pending.removeLast();
          emit(offset, first);
        }
      }
      return LogPage(entries, null, start);
    } finally {
      await file.close();
    }
  }

  /// Entries appended to the file after byte [from], as they come,
  /// checking every [interval]. A file that shrinks (rotated or cleared)
  /// is read again from its start. Cancel the subscription to stop.
  Stream<LogEntry> tail({
    required int from,
    Duration interval = const Duration(seconds: 1),
  }) async* {
    var offset = from;
    final buffer = BytesBuilder(copy: false);
    int? entryOffset;
    var entryLines = <String>[];
    var entryLength = 0;

    LogEntry? flush() {
      if (entryOffset == null) {
        return null;
      }
      final entry = LogEntry.parse(
        entryLines.join('\n'),
        entryOffset!,
        entryLength,
      );
      entryOffset = null;
      entryLines = [];
      entryLength = 0;
      return entry;
    }

    while (true) {
      final file = File(path);
      final length = await file.exists() ? await file.length() : 0;
      if (length < offset) {
        offset = 0;
        buffer.clear();
      }
      var read = false;
      if (length > offset) {
        final handle = await file.open();
        try {
          await handle.setPosition(offset);
          buffer.add(
            await handle.read(math.min(length - offset, 8 * 1024 * 1024)),
          );
        } finally {
          await handle.close();
        }
        final bytes = buffer.takeBytes();
        final lastNewline = bytes.lastIndexOf(0x0A);
        final complete = lastNewline < 0 ? 0 : lastNewline + 1;
        buffer.add(Uint8List.sublistView(bytes, complete));
        var lineStart = 0;
        for (var i = 0; i < complete; i++) {
          if (bytes[i] != 0x0A) {
            continue;
          }
          var lineEnd = i;
          if (lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D) {
            lineEnd--;
          }
          final text = utf8.decode(
            Uint8List.sublistView(bytes, lineStart, lineEnd),
            allowMalformed: true,
          );
          final lineOffset = offset + lineStart;
          if (LogEntry.startsEntry(text) || entryOffset == null) {
            final done = flush();
            if (done != null) {
              yield done;
            }
            entryOffset = lineOffset;
          }
          entryLines.add(text);
          entryLength += i + 1 - lineStart;
          lineStart = i + 1;
        }
        offset += complete;
        read = complete > 0;
      }
      if (!read) {
        // Nothing new: the entry being gathered is complete.
        final done = flush();
        if (done != null) {
          yield done;
        }
      }
      await Future<void>.delayed(interval);
    }
  }
}
