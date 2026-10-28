import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mime/mime.dart';

/// An email address with an optional display name: `Teo <teo@example.com>`.
final class MailAddress {
  /// Throws [ArgumentError] for an address that is not `local@domain` or
  /// that contains line breaks (header injection).
  MailAddress(String email, [this.name]) : email = email.trim() {
    if (!_valid.hasMatch(this.email)) {
      throw ArgumentError.value(email, 'email', 'Not an email address');
    }
    final display = name;
    if (display != null && _breaks.hasMatch(display)) {
      throw ArgumentError.value(display, 'name', 'Contains a line break');
    }
  }

  /// `teo@example.com` or `Teo Prayoga <teo@example.com>`.
  factory MailAddress.parse(String value) {
    final match = RegExp(r'^\s*(.*?)\s*<([^<>]+)>\s*$').firstMatch(value);
    if (match == null) {
      return MailAddress(value);
    }
    var name = match[1]!;
    if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
      name = name.substring(1, name.length - 1).replaceAll(r'\"', '"');
    }
    return MailAddress(match[2]!, name.isEmpty ? null : name);
  }

  static final RegExp _valid = RegExp(r'^[^\s@<>()",;:\\]+@[^\s@<>()",;:\\]+$');
  static final RegExp _breaks = RegExp('[\r\n\u0000]');

  final String email;
  final String? name;

  /// The domain part (`example.com`).
  String get domain => email.substring(email.lastIndexOf('@') + 1);

  /// The header form, the name quoted or RFC 2047-encoded as needed.
  String get header {
    final display = name;
    if (display == null || display.isEmpty) {
      return email;
    }
    final encoded = _isAscii(display)
        ? (RegExp(r'^[A-Za-z0-9!#$%&*+/=?^_`{|}~ .-]+$').hasMatch(display)
              ? display
              : '"${display.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"')
        : encodeHeaderWord(display);
    return '$encoded <$email>';
  }

  @override
  bool operator ==(Object other) =>
      other is MailAddress && other.email.toLowerCase() == email.toLowerCase();

  @override
  int get hashCode => email.toLowerCase().hashCode;

  @override
  String toString() => header;
}

/// A file attached to a message.
final class MailAttachment {
  MailAttachment.bytes(List<int> data, this.filename, {String? contentType})
    : _data = data,
      _path = null,
      contentType = _checkedType(
        contentType ?? lookupMimeType(filename) ?? 'application/octet-stream',
      );

  /// Read when the message is rendered; [as] renames it.
  MailAttachment.file(String path, {String? as, String? contentType})
    : _data = null,
      _path = path,
      filename = as ?? path.split(RegExp(r'[\\/]')).last,
      contentType = _checkedType(
        contentType ?? lookupMimeType(as ?? path) ?? 'application/octet-stream',
      );

  /// The content type goes straight into a part header: a line break in it
  /// would inject headers, so it must be a plain media type.
  static String _checkedType(String contentType) {
    if (MailAddress._breaks.hasMatch(contentType) ||
        !RegExp(r'^[\w.+-]+/[\w.+-]+(;.*)?$').hasMatch(contentType)) {
      throw ArgumentError.value(
        contentType,
        'contentType',
        'must be a media type without line breaks',
      );
    }
    return contentType;
  }

  final List<int>? _data;
  final String? _path;
  final String filename;
  final String contentType;

  List<int> get bytes => _data ?? File(_path!).readAsBytesSync();

  /// The bytes go along (base64), so a queued message is self-contained.
  Map<String, Object?> toJson() => {
    'filename': filename,
    'content_type': contentType,
    'data': base64.encode(bytes),
  };

  factory MailAttachment.fromJson(Map<String, Object?> json) =>
      MailAttachment.bytes(
        base64.decode(json['data']! as String),
        json['filename']! as String,
        contentType: json['content_type'] as String?,
      );
}

/// A message ready to send: what a [Mailable] renders to.
final class MailMessage {
  MailMessage({
    required this.from,
    required this.subject,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.replyTo = const [],
    this.html,
    this.text,
    this.attachments = const [],
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable(headers) {
    if (MailAddress._breaks.hasMatch(subject)) {
      throw ArgumentError.value(subject, 'subject', 'Contains a line break');
    }
    for (final MapEntry(:key, :value) in headers.entries) {
      if (!RegExp(r'^[!-9;-~]+$').hasMatch(key) ||
          MailAddress._breaks.hasMatch(value)) {
        throw ArgumentError.value('$key: $value', 'headers', 'Invalid header');
      }
    }
    if (html == null && text == null) {
      throw ArgumentError('A message needs an html or a text body.');
    }
  }

  final MailAddress from;
  final List<MailAddress> to;
  final List<MailAddress> cc;

  /// Recipients that get the message without appearing in its headers.
  final List<MailAddress> bcc;
  final List<MailAddress> replyTo;
  final String subject;
  final String? html;
  final String? text;
  final List<MailAttachment> attachments;
  final Map<String, String> headers;

  /// The message as JSON (a queued mail's payload).
  Map<String, Object?> toJson() => {
    'from': _address(from),
    'to': to.map(_address).toList(),
    'cc': cc.map(_address).toList(),
    'bcc': bcc.map(_address).toList(),
    'reply_to': replyTo.map(_address).toList(),
    'subject': subject,
    'html': html,
    'text': text,
    'attachments': [for (final a in attachments) a.toJson()],
    'headers': headers,
  };

  factory MailMessage.fromJson(Map<String, Object?> json) {
    List<MailAddress> list(String key) => [
      for (final item in (json[key] as List<Object?>?) ?? const [])
        _fromAddress(item),
    ];
    return MailMessage(
      from: _fromAddress(json['from']),
      to: list('to'),
      cc: list('cc'),
      bcc: list('bcc'),
      replyTo: list('reply_to'),
      subject: json['subject']! as String,
      html: json['html'] as String?,
      text: json['text'] as String?,
      attachments: [
        for (final item in (json['attachments'] as List<Object?>?) ?? const [])
          MailAttachment.fromJson((item! as Map).cast<String, Object?>()),
      ],
      headers: ((json['headers'] as Map?) ?? const {}).cast<String, String>(),
    );
  }

  static Map<String, Object?> _address(MailAddress a) => {
    'email': a.email,
    'name': a.name,
  };

  static MailAddress _fromAddress(Object? json) {
    final map = (json! as Map).cast<String, Object?>();
    return MailAddress(map['email']! as String, map['name'] as String?);
  }

  /// Everyone the message is delivered to (to, cc and bcc, once each).
  List<MailAddress> get recipients => {...to, ...cc, ...bcc}.toList();

  bool hasTo(String email) => _has(to, email);
  bool hasCc(String email) => _has(cc, email);
  bool hasBcc(String email) => _has(bcc, email);

  static bool _has(List<MailAddress> list, String email) =>
      list.any((a) => a.email.toLowerCase() == email.toLowerCase());

  /// The RFC 5322 message, CRLF line endings.
  String toMime({required String messageId, required DateTime date}) {
    final random = Random.secure();
    String boundary() =>
        '=_daravel_${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final out = StringBuffer();
    void header(String name, String value) => out.write(_fold('$name: $value'));
    header('From', from.header);
    if (to.isNotEmpty) header('To', to.map((a) => a.header).join(', '));
    if (cc.isNotEmpty) header('Cc', cc.map((a) => a.header).join(', '));
    if (replyTo.isNotEmpty) {
      header('Reply-To', replyTo.map((a) => a.header).join(', '));
    }
    header('Subject', _isAscii(subject) ? subject : encodeHeaderWord(subject));
    header('Date', formatMailDate(date));
    header('Message-ID', '<$messageId>');
    for (final MapEntry(:key, :value) in headers.entries) {
      header(key, _isAscii(value) ? value : encodeHeaderWord(value));
    }
    header('MIME-Version', '1.0');

    final body = _alternative(boundary);
    if (attachments.isEmpty) {
      out
        ..write(body.headers)
        ..write('\r\n')
        ..write(body.content);
      return out.toString();
    }
    final mixed = boundary();
    out
      ..write('Content-Type: multipart/mixed; boundary="$mixed"\r\n')
      ..write('\r\n')
      ..write('--$mixed\r\n')
      ..write(body.headers)
      ..write('\r\n')
      ..write(body.content);
    for (final attachment in attachments) {
      out
        ..write('\r\n--$mixed\r\n')
        ..write(
          'Content-Type: ${attachment.contentType}; '
          'name="${_asciiFilename(attachment.filename)}"\r\n',
        )
        ..write('Content-Transfer-Encoding: base64\r\n')
        ..write(
          _fold(
            'Content-Disposition: attachment; '
            '${_filenameParameter(attachment.filename)}',
          ),
        )
        ..write('\r\n')
        ..write(_base64Lines(attachment.bytes));
    }
    out.write('\r\n--$mixed--\r\n');
    return out.toString();
  }

  /// The body without attachments: one part, or text and html together.
  ({String headers, String content}) _alternative(String Function() boundary) {
    ({String headers, String content}) part(String type, String value) => (
      headers:
          'Content-Type: $type; charset=utf-8\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n',
      content: '${encodeQuotedPrintable(value)}\r\n',
    );
    final plain = text;
    final rich = html;
    if (plain != null && rich != null) {
      final b = boundary();
      final textPart = part('text/plain', plain);
      final htmlPart = part('text/html', rich);
      return (
        headers: 'Content-Type: multipart/alternative; boundary="$b"\r\n',
        content:
            '--$b\r\n${textPart.headers}\r\n${textPart.content}'
            '--$b\r\n${htmlPart.headers}\r\n${htmlPart.content}'
            '--$b--\r\n',
      );
    }
    return rich != null ? part('text/html', rich) : part('text/plain', plain!);
  }
}

bool _isAscii(String value) => value.codeUnits.every((c) => c < 128);

/// [value] as RFC 2047 encoded words (`=?utf-8?B?...?=`), each at most 75
/// characters and split between characters, never inside one.
String encodeHeaderWord(String value) {
  final words = <String>[];
  final chunk = StringBuffer();
  var size = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final bytes = utf8.encode(char).length;
    // 45 bytes encode to 60 base64 characters: 72 with the delimiters.
    if (size + bytes > 45) {
      words.add(chunk.toString());
      chunk.clear();
      size = 0;
    }
    chunk.write(char);
    size += bytes;
  }
  if (chunk.isNotEmpty) {
    words.add(chunk.toString());
  }
  return words
      .map((w) => '=?utf-8?B?${base64.encode(utf8.encode(w))}?=')
      .join('\r\n ');
}

/// A header line folded at spaces after commas to stay under 78 columns,
/// with its CRLF.
String _fold(String line) {
  if (line.length <= 78 || line.contains('\r\n')) {
    return '$line\r\n';
  }
  final out = StringBuffer();
  var current = '';
  for (final piece in line.split(', ')) {
    final next = current.isEmpty ? piece : '$current, $piece';
    if (next.length > 76 && current.isNotEmpty) {
      out.write('$current,\r\n');
      current = ' $piece';
    } else {
      current = next;
    }
  }
  out.write('$current\r\n');
  return out.toString();
}

/// RFC 5322 date: `Mon, 26 Oct 2026 08:00:00 +0000`.
String formatMailDate(DateTime date) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final d = date.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]} ${d.year} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)} +0000';
}

/// RFC 2045 quoted-printable of [text] as UTF-8, CRLF line endings, lines
/// at most 76 characters (soft breaks end with `=`).
String encodeQuotedPrintable(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final out = <String>[];
  for (final line in lines) {
    final bytes = utf8.encode(line);
    final encoded = StringBuffer();
    var length = 0;
    void emit(String piece) {
      if (length + piece.length > 75) {
        encoded.write('=\r\n');
        length = 0;
      }
      encoded.write(piece);
      length += piece.length;
    }

    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      final last = i == bytes.length - 1;
      final literal =
          (b >= 33 && b <= 126 && b != 61) || ((b == 32 || b == 9) && !last);
      // A leading dot is escaped so no line is a lone "." (SMTP's end).
      if (literal && !(b == 46 && length == 0)) {
        emit(String.fromCharCode(b));
      } else {
        emit('=${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    out.add(encoded.toString());
  }
  return out.join('\r\n');
}

String _base64Lines(List<int> bytes) {
  final encoded = base64.encode(bytes);
  final out = StringBuffer();
  for (var i = 0; i < encoded.length; i += 76) {
    out
      ..write(encoded.substring(i, min(i + 76, encoded.length)))
      ..write('\r\n');
  }
  return out.toString();
}

String _asciiFilename(String name) =>
    name.replaceAll(RegExp(r'[^\x20-\x7E]|["\\]'), '_');

/// `filename="a.pdf"`, or RFC 2231 `filename*=utf-8''...` for other names.
String _filenameParameter(String name) => _isAscii(name)
    ? 'filename="${_asciiFilename(name)}"'
    : "filename*=utf-8''${Uri.encodeComponent(name)}";
