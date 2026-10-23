import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'headers.dart';
import 'request.dart';

/// Objects that know how to turn themselves into a [Response].
abstract interface class Responsable {
  Response toResponse(Request request);
}

/// Objects that provide a JSON representation.
abstract interface class JsonSerializable {
  Object? toJson();
}

/// Body of a [Response].
sealed class ResponseBody {
  const ResponseBody();
}

final class EmptyBody extends ResponseBody {
  const EmptyBody();
}

final class BytesBody extends ResponseBody {
  const BytesBody(this.bytes);

  final List<int> bytes;
}

final class StreamBody extends ResponseBody {
  const StreamBody(this.stream, {this.contentLength});

  final Stream<List<int>> stream;
  final int? contentLength;
}

/// Immutable HTTP response (BLUEPRINT_V2 §7.2.3).
final class Response {
  Response({
    this.status = 200,
    Headers? headers,
    this.body = const EmptyBody(),
    this.contentLengthOverride,
  }) : headers = headers ?? Headers();

  /// JSON response (`application/json`). [data] may contain maps, lists,
  /// numbers, strings, booleans, `null`, [DateTime] (ISO-8601 UTC), enums and
  /// [JsonSerializable] objects.
  factory Response.json(
    Object? data, {
    int status = 200,
    Map<String, String>? headers,
  }) => Response(
    status: status,
    headers: _headersWithType('application/json', headers),
    body: BytesBody(utf8.encode(encodeJson(data))),
  );

  /// `201 Created` JSON response with optional `Location` header.
  factory Response.created(Object? data, {String? location}) => Response.json(
    data,
    status: 201,
    headers: location == null ? null : <String, String>{'location': location},
  );

  /// `204 No Content`.
  factory Response.noContent({Map<String, String>? headers}) =>
      Response(status: 204, headers: Headers(headers));

  /// Plain text response.
  factory Response.text(
    String body, {
    int status = 200,
    Map<String, String>? headers,
  }) => Response(
    status: status,
    headers: _headersWithType('text/plain; charset=utf-8', headers),
    body: BytesBody(utf8.encode(body)),
  );

  /// HTML response.
  factory Response.html(
    String html, {
    int status = 200,
    Map<String, String>? headers,
  }) => Response(
    status: status,
    headers: _headersWithType('text/html; charset=utf-8', headers),
    body: BytesBody(utf8.encode(html)),
  );

  /// Redirect response.
  factory Response.redirect(String location, {int status = 302}) => Response(
    status: status,
    headers: Headers(<String, Object>{'location': location}),
  );

  /// Raw bytes with an explicit content type.
  factory Response.bytes(
    List<int> bytes, {
    required String contentType,
    int status = 200,
    Map<String, String>? headers,
  }) => Response(
    status: status,
    headers: _headersWithType(contentType, headers),
    body: BytesBody(bytes),
  );

  /// Streamed body with an explicit content type.
  factory Response.stream(
    Stream<List<int>> stream, {
    required String contentType,
    int status = 200,
    int? contentLength,
    Map<String, String>? headers,
  }) => Response(
    status: status,
    headers: _headersWithType(contentType, headers),
    body: StreamBody(stream, contentLength: contentLength),
  );

  final int status;
  final Headers headers;
  final ResponseBody body;

  /// Content length to advertise when the body was stripped (HEAD requests).
  final int? contentLengthOverride;

  static final JsonEncoder _encoder = JsonEncoder(_toEncodable);

  /// Encodes [data] with the framework's JSON conventions.
  static String encodeJson(Object? data) => _encoder.convert(data);

  static Object? _toEncodable(Object? value) {
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is JsonSerializable) {
      return value.toJson();
    }
    if (value is Enum) {
      return value.name;
    }
    throw JsonUnsupportedObjectError(value);
  }

  static Headers _headersWithType(
    String contentType,
    Map<String, String>? extra,
  ) {
    final headers = Headers(extra);
    headers.set('content-type', contentType);
    return headers;
  }

  /// Copy with [name] set to [value].
  Response withHeader(String name, String value) {
    final copy = headers.copy()..set(name, value);
    return _copyWith(headers: copy);
  }

  /// Copy with all [values] set.
  Response withHeaders(Map<String, String> values) {
    final copy = headers.copy();
    values.forEach(copy.set);
    return _copyWith(headers: copy);
  }

  /// Copy with a different [status].
  Response withStatus(int status) => _copyWith(status: status);

  /// Copy without a body (used for `HEAD`), keeping the advertised length.
  Response withoutBody() {
    final length = switch (body) {
      BytesBody(:final bytes) => bytes.length,
      StreamBody(:final contentLength) => contentLength,
      EmptyBody() => contentLengthOverride,
    };
    return Response(
      status: status,
      headers: headers.copy(),
      contentLengthOverride: length,
    );
  }

  Response _copyWith({int? status, Headers? headers}) => Response(
    status: status ?? this.status,
    headers: headers ?? this.headers,
    body: body,
    contentLengthOverride: contentLengthOverride,
  );

  /// Collects the body as bytes (consumes stream bodies).
  Future<List<int>> bodyBytes() async {
    switch (body) {
      case EmptyBody():
        return const <int>[];
      case BytesBody(:final bytes):
        return bytes;
      case StreamBody(:final stream):
        final builder = BytesBuilder(copy: false);
        await for (final chunk in stream) {
          builder.add(chunk);
        }
        return builder.takeBytes();
    }
  }

  /// Collects the body as a UTF-8 string.
  Future<String> bodyText() async => utf8.decode(await bodyBytes());

  /// Writes this response to a `dart:io` [HttpResponse] and closes it.
  Future<void> writeTo(HttpResponse out) async {
    out.statusCode = status;
    for (final entry in headers.entries) {
      if (entry.key == 'content-length') {
        continue;
      }
      for (final value in entry.value) {
        out.headers.add(entry.key, value);
      }
    }
    final allowsBody = status >= 200 && status != 204 && status != 304;
    switch (body) {
      case EmptyBody():
        if (allowsBody) {
          out.contentLength = contentLengthOverride ?? 0;
        }
      case BytesBody(:final bytes):
        if (allowsBody) {
          out.contentLength = bytes.length;
          out.add(bytes);
        }
      case StreamBody(:final stream, :final contentLength):
        if (contentLength != null) {
          out.contentLength = contentLength;
        }
        await out.addStream(stream);
    }
    await out.close();
  }
}
