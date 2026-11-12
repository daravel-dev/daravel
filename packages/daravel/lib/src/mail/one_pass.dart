/// One-pass replacements for the regular expressions mail rendering used.
///
/// Each function gives what the `replaceAllMapped` (or `firstMatch`) it
/// names gave, on every input. Those expressions scanned to the end of the
/// text from every opening tag or bracket without its closing one, so a
/// message body of 64 KiB took up to 80 s, and markdown mail runs them on
/// every message. Here each opener costs a few lookups.
library;

import '../foundation/regexp_chars.dart';

/// `text.replaceAllMapped(RegExp(r'<x-mail::button\b([^>]*)>(.*?)</x-mail::button>', dotAll: true), …)`,
/// with [replace] given groups 1 and 2.
///
/// From an opener the expression takes the first `>` after it and then the
/// first closing tag after that `>`. Without a `>`, or without a closing
/// tag after it, no later opener can match either.
String replaceButtonTags(
  String text,
  String Function(String attributes, String inner) replace,
) {
  const open = '<x-mail::button';
  const close = '</x-mail::button>';
  final out = StringBuffer();
  var copied = 0;
  var from = 0;
  while (true) {
    final start = text.indexOf(open, from);
    if (start < 0) {
      break;
    }
    final afterOpen = start + open.length;
    if (afterOpen < text.length && isRegExpWord(text.codeUnitAt(afterOpen))) {
      from = start + 1;
      continue;
    }
    final gt = text.indexOf('>', afterOpen);
    if (gt < 0) {
      break;
    }
    final end = text.indexOf(close, gt + 1);
    if (end < 0) {
      break;
    }
    out
      ..write(text.substring(copied, start))
      ..write(
        replace(text.substring(afterOpen, gt), text.substring(gt + 1, end)),
      );
    copied = from = end + close.length;
  }
  if (copied == 0) {
    return text;
  }
  out.write(text.substring(copied));
  return out.toString();
}

/// `text.replaceAllMapped(RegExp(r'<x-mail::panel>(.*?)</x-mail::panel>', dotAll: true), …)`,
/// with [replace] given group 1: from an opener, the first closing tag;
/// without one, no later opener matches.
String replacePanelTags(String text, String Function(String inner) replace) {
  const open = '<x-mail::panel>';
  const close = '</x-mail::panel>';
  final out = StringBuffer();
  var copied = 0;
  var from = 0;
  while (true) {
    final start = text.indexOf(open, from);
    if (start < 0) {
      break;
    }
    final end = text.indexOf(close, start + open.length);
    if (end < 0) {
      break;
    }
    out
      ..write(text.substring(copied, start))
      ..write(replace(text.substring(start + open.length, end)));
    copied = from = end + close.length;
  }
  if (copied == 0) {
    return text;
  }
  out.write(text.substring(copied));
  return out.toString();
}

/// `text.replaceAllMapped(RegExp('$open${boundary ? r'\b' : ''}[^>]*$attribute="([^"]*)"[^>]*>(.*?)$close', dotAll: true), …)`,
/// with [replace] given groups 1 and 2: the tags
/// `<x-mail::button … url="…" …>…</x-mail::button>` and
/// `<a … href="…" …>…</a>` of [markdownToText].
///
/// From an opener, `[^>]*` reaches at most the first `>` (call it g), and
/// backtracks to the last `attribute="` that ends before g (the largest
/// candidate). Its value ends at the first `"` after it, which may lie past
/// g; the tag at the first `>` after that `"`; the content at the first
/// closing tag after that `>`. If that fails, the next candidate is tried.
/// Every smaller candidate's value ends at a `"` before g (the quote of the
/// candidate after it), so its tag ends at g itself, and all of them reach
/// the same closing tag: the second largest decides for all of them.
/// Positions of `"`, `>`, the closing tag and the attribute are found
/// once, so each opener costs a few binary searches.
String replaceAttributeTags(
  String text, {
  required String open,
  required bool boundary,
  required String attribute,
  required String close,
  required String Function(String value, String inner) replace,
}) {
  if (!text.contains(open)) {
    return text;
  }
  final marker = '$attribute="';
  final quotes = _positions(text, '"');
  final gts = _positions(text, '>');
  final closes = _positions(text, close);
  final markers = _positions(text, marker);
  final out = StringBuffer();
  var copied = 0;
  var from = 0;
  while (true) {
    final start = text.indexOf(open, from);
    if (start < 0) {
      break;
    }
    from = start + 1;
    final afterOpen = start + open.length;
    if (boundary &&
        afterOpen < text.length &&
        isRegExpWord(text.codeUnitAt(afterOpen))) {
      continue;
    }
    final firstGt = _firstAtLeast(gts, afterOpen);
    final limit = firstGt ?? text.length;
    // The candidates: markers starting at afterOpen or later and ending
    // at limit or before.
    var index = _lastAtMost(markers, limit - marker.length);
    (String, String, int)? match;
    for (var tries = 0; tries < 2 && index >= 0; tries++, index--) {
      final candidate = markers[index];
      if (candidate < afterOpen) {
        break;
      }
      final valueStart = candidate + marker.length;
      final quote = _firstAtLeast(quotes, valueStart);
      final tagEnd = quote == null ? null : _firstAtLeast(gts, quote + 1);
      final end = tagEnd == null ? null : _firstAtLeast(closes, tagEnd + 1);
      if (end != null) {
        match = (
          text.substring(valueStart, quote),
          text.substring(tagEnd! + 1, end),
          end + close.length,
        );
        break;
      }
    }
    if (match == null) {
      continue;
    }
    final (value, inner, matchEnd) = match;
    out
      ..write(text.substring(copied, start))
      ..write(replace(value, inner));
    copied = from = matchEnd;
  }
  if (copied == 0) {
    return text;
  }
  out.write(text.substring(copied));
  return out.toString();
}

/// `text.replaceAll(RegExp(r'<[^>]+>'), '')`: from a `<`, the first `>`
/// after it ends the tag unless it follows at once (`<>` is no tag);
/// without a `>`, nothing later matches.
String removeTags(String text) {
  final out = StringBuffer();
  var copied = 0;
  var from = 0;
  while (true) {
    final lt = text.indexOf('<', from);
    if (lt < 0) {
      break;
    }
    final gt = text.indexOf('>', lt + 1);
    if (gt < 0) {
      break;
    }
    if (gt == lt + 1) {
      from = gt;
      continue;
    }
    out.write(text.substring(copied, lt));
    copied = from = gt + 1;
  }
  if (copied == 0) {
    return text;
  }
  out.write(text.substring(copied));
  return out.toString();
}

/// `text.replaceAllMapped(RegExp(r'\[([^\]]*)\]\(([^)]*)\)'), …)`, with
/// [replace] given groups 1 and 2. From a `[`, the first `]` after it; a
/// `(` right after; then the first `)`. When the `(` is missing, every `[`
/// before that `]` fails the same way; without a `]` or a `)`, nothing
/// later matches.
String replaceLinks(
  String text,
  String Function(String label, String target) replace,
) {
  final out = StringBuffer();
  var copied = 0;
  var from = 0;
  while (true) {
    final open = text.indexOf('[', from);
    if (open < 0) {
      break;
    }
    final close = text.indexOf(']', open + 1);
    if (close < 0) {
      break;
    }
    if (close + 1 >= text.length || text.codeUnitAt(close + 1) != 0x28) {
      from = close + 1;
      continue;
    }
    final end = text.indexOf(')', close + 2);
    if (end < 0) {
      break;
    }
    out
      ..write(text.substring(copied, open))
      ..write(
        replace(
          text.substring(open + 1, close),
          text.substring(close + 2, end),
        ),
      );
    copied = from = end + 1;
  }
  if (copied == 0) {
    return text;
  }
  out.write(text.substring(copied));
  return out.toString();
}

/// What `RegExp(r'^\s*(.*?)\s*<([^<>]+)>\s*$').firstMatch(value)` gave as
/// groups 1 and 2, or null where it did not match.
///
/// After `>` only white space may follow, so `>` is the last character
/// that is not white space; the address runs back to the last `<` before
/// it and may hold no `>`. The name is what lies before that `<` without
/// the white space around it, and holds no line terminator (`.`).
(String, String)? nameAndAddress(String value) {
  var end = value.length;
  while (end > 0 && isRegExpSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  if (end == 0 || value.codeUnitAt(end - 1) != 0x3E) {
    return null;
  }
  final gt = end - 1;
  if (gt == 0) {
    return null;
  }
  final lt = value.lastIndexOf('<', gt - 1);
  if (lt < 0 || lt == gt - 1 || value.lastIndexOf('>', gt - 1) > lt) {
    return null;
  }
  var start = 0;
  while (start < lt && isRegExpSpace(value.codeUnitAt(start))) {
    start++;
  }
  var nameEnd = lt;
  while (nameEnd > start && isRegExpSpace(value.codeUnitAt(nameEnd - 1))) {
    nameEnd--;
  }
  for (var i = start; i < nameEnd; i++) {
    if (isLineTerminator(value.codeUnitAt(i))) {
      return null;
    }
  }
  return (value.substring(start, nameEnd), value.substring(lt + 1, gt));
}

/// The start of every occurrence of [pattern] in [text], in order
/// (occurrences may overlap).
List<int> _positions(String text, String pattern) {
  final positions = <int>[];
  for (
    var at = text.indexOf(pattern);
    at >= 0;
    at = text.indexOf(pattern, at + 1)
  ) {
    positions.add(at);
  }
  return positions;
}

/// The first of [sorted] at [value] or after, or null.
int? _firstAtLeast(List<int> sorted, int value) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (sorted[middle] < value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low < sorted.length ? sorted[low] : null;
}

/// The index of the last of [sorted] at [value] or before, or -1.
int _lastAtMost(List<int> sorted, int value) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (sorted[middle] <= value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low - 1;
}
