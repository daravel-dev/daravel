import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../foundation/clock.dart';
import '../foundation/php.dart';
import '../foundation/php_serialize.dart';
import 'cookies.dart';
import 'file_response.dart';
import 'headers.dart';
import 'json_stream.dart';
import 'realtime.dart';
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
    this.webSocket,
    this.webSocketCompression = true,
    this.webSocketMaxPayloadBytes = defaultWebSocketMaxPayloadBytes,
    this.exception,
  }) : headers = headers ?? Headers();

  /// Laravel's `$response->exception`: what this response was rendered
  /// from. An exception never passes through `next`, so this is how a
  /// middleware that used to catch one sees it, and how one wrapping a
  /// transaction knows to roll back.
  Object? exception;

  /// Laravel's `withException`.
  Response withException(Object error) {
    exception = error;
    return this;
  }

  /// The largest WebSocket frame a route accepts unless it says otherwise:
  /// 1 MiB. `dart:io` sets no limit of its own (its default is the largest
  /// integer unless the build defines
  /// `dart.io.default.ws.max.payload.length`), so one client could make a
  /// worker buffer a frame of any size.
  static const int defaultWebSocketMaxPayloadBytes = 1 << 20;

  /// JSON response (`application/json`). [data] may contain maps, lists,
  /// numbers, strings, booleans, `null`, [DateTime] (ISO-8601 UTC), enums and
  /// [JsonSerializable] objects.
  ///
  /// [phpCompatible] writes the bytes of PHP's `json_encode()` (what a
  /// Laravel response sends), for clients that compare or sign them: `/`,
  /// `Xxxx` for non-ASCII, and `[]` for an empty map (an empty PHP
  /// array). Same values, so any JSON parser reads both alike.
  factory Response.json(
    Object? data, {
    int status = 200,
    Map<String, String>? headers,
    bool phpCompatible = false,
  }) => Response(
    status: status,
    headers: _headersWithType('application/json', headers),
    body: BytesBody(
      utf8.encode(phpCompatible ? encodePhpJson(data) : encodeJson(data)),
    ),
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
  /// Laravel's `back()`: to the `Referer` when it is this site, else
  /// [previous] (the session's previous URL), else [fallback]. A foreign
  /// `Referer` is ignored, so it cannot make this an open redirect.
  ///
  /// Inertia needs 303 after PUT, PATCH and DELETE: browsers repeat the
  /// method on a 302.
  factory Response.back(
    Request request, {
    String fallback = '/',
    String? previous,
    int? status,
  }) {
    final referer = Uri.tryParse(request.headers.first('referer') ?? '');
    final sameSite =
        referer != null &&
        referer.hasAuthority &&
        referer.authority == request.uri.authority;
    return Response.redirect(
      sameSite ? referer.toString() : previous ?? fallback,
      status:
          status ??
          (request.headers.first('x-inertia') == 'true' &&
                  const {'PUT', 'PATCH', 'DELETE'}.contains(request.method)
              ? 303
              : 302),
    );
  }

  /// `response()->download()`: [fileOrPath], a `File` or a path, as an
  /// attachment. [deleteFileAfterSend] removes it once it was sent, for a
  /// report made for this request. A missing file is a 404.
  static Future<Response> download(
    Object fileOrPath, {
    String? name,
    Map<String, String>? headers,
    bool deleteFileAfterSend = false,
    Request? request,
  }) => sendFile(
    fileOrPath,
    inline: false,
    name: name,
    headers: headers,
    request: request,
    deleteAfterSend: deleteFileAfterSend,
  );

  /// `response()->file()`: shown by the browser. Pass [request] to answer
  /// `Range` (206), which PDF viewers and iOS media players need, and
  /// conditional requests. Never build [fileOrPath] from user input.
  static Future<Response> file(
    Object fileOrPath, {
    Request? request,
    String? name,
    String? contentType,
    Map<String, String>? headers,
  }) => sendFile(
    fileOrPath,
    inline: true,
    name: name,
    contentType: contentType,
    headers: headers,
    request: request,
  );

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

  /// Server-sent events (Laravel's `response()->eventStream()`): each item of
  /// [events] (an [SseEvent], or a value sent as an `update` event) is
  /// written as it comes, a `: keep-alive` comment every [heartbeat] keeps
  /// proxies from closing an idle stream, and [endStreamWith] (`</stream>`,
  /// as Laravel; `null` for none) closes it. The stream also ends when the
  /// server starts draining, so `EventSource` reconnects elsewhere. A client
  /// that went away is noticed at the next event or heartbeat (TCP reports
  /// nothing on an idle connection), which then cancels [events].
  factory Response.sse(
    Stream<Object?> events, {
    Object? endStreamWith = '</stream>',
    Duration? heartbeat = const Duration(seconds: 15),
    Map<String, String>? headers,
  }) => Response(
    headers: Headers(<String, Object>{
      ...?headers,
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      'x-accel-buffering': 'no',
    }),
    body: StreamBody(
      sseStream(events, endStreamWith: endStreamWith, heartbeat: heartbeat),
    ),
  );

  /// Switches the connection to a WebSocket (`router.ws` returns this after
  /// the route's middleware passed); [handler] gets the socket inside the
  /// request's scope. [compress] false turns permessage-deflate off: no
  /// compression state per connection, which matters with many of them.
  factory Response.webSocket(
    WebSocketHandler handler, {
    bool compress = true,
    int maxPayloadBytes = defaultWebSocketMaxPayloadBytes,
  }) => Response(
    status: 101,
    webSocket: handler,
    webSocketCompression: compress,
    webSocketMaxPayloadBytes: maxPayloadBytes,
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

  /// A JSON array of [items] written as they arrive (Laravel's
  /// `response()->streamJson()`): the same bytes as [Response.json] of the
  /// collected list, in chunks, so a large result set is never held whole.
  /// Feed it `DB.table('users').lazy()` or any stream of encodable values;
  /// [wrap] puts the array under a key, `{"data":[...]}`, and
  /// [phpCompatible] writes PHP's `json_encode()` bytes. See
  /// [jsonArrayBytes].
  factory Response.streamJson(
    Stream<Object?> items, {
    int status = 200,
    Map<String, String>? headers,
    bool phpCompatible = false,
    String? wrap,
  }) => Response.stream(
    jsonArrayBytes(items, phpCompatible: phpCompatible, wrap: wrap),
    contentType: 'application/json',
    status: status,
    headers: headers,
  );

  final int status;
  final Headers headers;
  final ResponseBody body;

  /// Set by [Response.webSocket]: the server upgrades the connection and
  /// hands the socket to this handler.
  final WebSocketHandler? webSocket;

  /// Whether the WebSocket offers permessage-deflate to clients that ask.
  final bool webSocketCompression;

  /// The largest frame the WebSocket accepts (uncompressed bytes); a
  /// larger one fails the connection ([defaultWebSocketMaxPayloadBytes]).
  final int webSocketMaxPayloadBytes;

  /// Content length to advertise when the body was stripped (HEAD requests).
  final int? contentLengthOverride;

  static final JsonEncoder _encoder = JsonEncoder(_toEncodable);

  /// Encodes [data] with the framework's JSON conventions.
  static String encodeJson(Object? data) => _encoder.convert(data);

  static Object? _toEncodable(Object? value) {
    if (value is DateTime) {
      return jsonDate(value);
    }
    if (value is JsonSerializable) {
      return value.toJson();
    }
    if (value is Enum) {
      return value.name;
    }
    if (value is PhpObject) {
      return value.properties;
    }
    throw JsonUnsupportedObjectError(value);
  }

  /// The bytes of PHP's `json_encode()` for [data] (`phpCompatible`):
  /// escaped slashes and non-ASCII, an empty map as `[]` (an empty PHP
  /// array) and a [PhpObject] as an object, so
  /// `const PhpObject('stdClass', {})` is `{}` as `(object) []` is in PHP.
  ///
  /// One pass ([PhpJsonEncoder]): the same bytes as `jsonEncode` followed by
  /// [phpJsonFromDart], without the intermediate string and its rewrite.
  static String encodePhpJson(Object? data) => _phpEncoder.convert(data);

  static const PhpJsonEncoder _phpEncoder = PhpJsonEncoder(
    toEncodable: _toEncodable,
  );

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

  /// Copy with every value of [name] replaced by [values] (a multi-valued
  /// header such as `Set-Cookie`); an empty list removes the header.
  Response withHeaderList(String name, List<String> values) {
    final copy = headers.copy()..remove(name);
    for (final value in values) {
      copy.add(name, value);
    }
    return _copyWith(headers: copy);
  }

  /// Copy with a different [status].
  Response withStatus(int status) => _copyWith(status: status);

  /// Copy with a `Set-Cookie` header added (Laravel's `withCookie`), in
  /// the format Laravel writes. [maxAge] `null` makes a session cookie;
  /// the defaults are Laravel's (`path=/`, `httponly`, `samesite=lax`).
  /// The value is sent as is: Laravel's `EncryptCookies` is not applied.
  /// [partitioned] adds `Partitioned` (CHIPS), as Laravel's
  /// `SESSION_PARTITIONED_COOKIE`.
  Response withCookie(
    String name,
    String value, {
    Duration? maxAge,
    String path = '/',
    String? domain,
    bool secure = false,
    bool httpOnly = true,
    String? sameSite = 'lax',
    bool partitioned = false,
  }) {
    final copy = headers.copy()
      ..add(
        'set-cookie',
        formatSetCookie(
          name,
          value,
          maxAge: maxAge,
          path: path,
          domain: domain,
          secure: secure,
          httpOnly: httpOnly,
          sameSite: sameSite,
          partitioned: partitioned,
        ),
      );
    return _copyWith(headers: copy);
  }

  /// Copy that tells the client to delete the cookie [name] (Laravel's
  /// `withoutCookie` / `Cookie::forget`); [path] and [domain] must match
  /// the ones it was set with.
  Response withoutCookie(String name, {String path = '/', String? domain}) =>
      withCookie(name, '', path: path, domain: domain);

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
    webSocket: webSocket,
    webSocketCompression: webSocketCompression,
    webSocketMaxPayloadBytes: webSocketMaxPayloadBytes,
    exception: exception,
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
      // Replace, never append: a value list inherited from the server's
      // default headers is shared with every other response.
      out.headers.removeAll(entry.key);
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
        } else {
          // Chunked streams (server-sent events) go out as they come.
          out.bufferOutput = false;
        }
        await out.addStream(stream);
    }
    await out.close();
  }
}
