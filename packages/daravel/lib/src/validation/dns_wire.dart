/// The DNS wire format `SystemDnsResolver` needs for one MX question
/// (RFC 1035 §4), read defensively: the answer comes from the network, so
/// every offset is checked, compression pointers are followed a bounded
/// number of times, and a packet that does not parse is "unknown", never an
/// exception.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The DNS type of an MX record.
const int dnsTypeMx = 15;

/// What an answer packet says about the question that was asked.
sealed class MxAnswer {
  const MxAnswer();
}

/// Not the answer to our question (another id, another question, not a
/// response): ignore it and keep waiting.
final class MxMismatch extends MxAnswer {
  /// The packet answers something else.
  const MxMismatch();
}

/// The answer to our question, but it does not tell: truncated (TC), a
/// server failure, or a malformed body. The caller falls back to A/AAAA.
final class MxUnknown extends MxAnswer {
  /// Why the answer does not tell.
  const MxUnknown(this.reason);

  /// For the debug log.
  final String reason;
}

/// The MX targets of the name (empty when it has none or does not exist;
/// `''` is the root, a "null MX": the domain accepts no mail).
final class MxRecords extends MxAnswer {
  /// The targets, lower case, without the trailing dot.
  const MxRecords(this.targets);

  /// The exchange names.
  final List<String> targets;
}

/// The most answer records read from one packet.
const int maxAnswerRecords = 64;

/// The most compression pointers followed while reading one name.
const int maxPointerJumps = 16;

/// An MX query for [name] (ASCII, no trailing dot) with transaction [id],
/// recursion desired.
Uint8List buildMxQuery(int id, String name) {
  final out = BytesBuilder()
    ..add([id >> 8 & 0xff, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in name.split('.')) {
    final bytes = ascii.encode(label);
    out
      ..addByte(bytes.length)
      ..add(bytes);
  }
  out.add([0, 0, dnsTypeMx, 0, 1]);
  return out.toBytes();
}

/// Reads [packet] as the answer to the MX query [id] for [name].
///
/// The owner of an MX record is not matched against [name]: an MX reached
/// through a CNAME in the same answer counts, as a resolver returns it.
MxAnswer parseMxAnswer(
  Uint8List packet, {
  required int id,
  required String name,
}) {
  if (packet.length < 12) {
    return const MxMismatch();
  }
  int u16(int at) => packet[at] << 8 | packet[at + 1];
  if (u16(0) != id) {
    return const MxMismatch();
  }
  final flags = u16(2);
  final isResponse = flags & 0x8000 != 0;
  final opcode = flags >> 11 & 0xf;
  if (!isResponse || opcode != 0 || u16(4) != 1) {
    return const MxMismatch();
  }
  // The question must be ours, or the packet answers something else.
  final question = readDnsName(packet, 12);
  if (question == null || question.next + 4 > packet.length) {
    return const MxMismatch();
  }
  if (question.name != name.toLowerCase() ||
      u16(question.next) != dnsTypeMx ||
      u16(question.next + 2) != 1) {
    return const MxMismatch();
  }
  if (flags & 0x0200 != 0) {
    return const MxUnknown('truncated answer (TC)');
  }
  final rcode = flags & 0xf;
  if (rcode == 3) {
    return const MxRecords([]);
  }
  if (rcode != 0) {
    return MxUnknown('rcode $rcode');
  }
  final count = u16(6);
  final targets = <String>[];
  var at = question.next + 4;
  for (var i = 0; i < count && i < maxAnswerRecords; i++) {
    final owner = readDnsName(packet, at);
    if (owner == null || owner.next + 10 > packet.length) {
      return const MxUnknown('malformed answer record');
    }
    final type = u16(owner.next);
    final klass = u16(owner.next + 2);
    final length = u16(owner.next + 8);
    final data = owner.next + 10;
    if (data + length > packet.length) {
      return const MxUnknown('answer record past the end');
    }
    if (type == dnsTypeMx && klass == 1) {
      if (length < 3) {
        return const MxUnknown('short MX record');
      }
      final exchange = readDnsName(packet, data + 2);
      if (exchange == null || exchange.next > data + length) {
        return const MxUnknown('malformed MX exchange');
      }
      targets.add(exchange.name);
    }
    at = data + length;
  }
  return MxRecords(targets);
}

/// The name at [offset] of [packet] (lower case, no trailing dot; `''` for
/// the root) and the offset after it, or null when it is malformed: a label
/// or pointer past the end, a reserved label type, more than
/// [maxPointerJumps] pointers (a loop), or more than 255 bytes.
({String name, int next})? readDnsName(Uint8List packet, int offset) {
  final labels = <String>[];
  var at = offset;
  int? next;
  var jumps = 0;
  var total = 0;
  while (true) {
    if (at >= packet.length) {
      return null;
    }
    final length = packet[at];
    if (length == 0) {
      next ??= at + 1;
      break;
    }
    switch (length & 0xc0) {
      case 0xc0:
        if (at + 1 >= packet.length || ++jumps > maxPointerJumps) {
          return null;
        }
        next ??= at + 2;
        at = (length & 0x3f) << 8 | packet[at + 1];
      case 0x00:
        if (at + 1 + length > packet.length) {
          return null;
        }
        total += length + 1;
        if (total > 255) {
          return null;
        }
        labels.add(
          latin1.decode(packet.sublist(at + 1, at + 1 + length)).toLowerCase(),
        );
        at += 1 + length;
      default:
        return null;
    }
  }
  return (name: labels.join('.'), next: next);
}
