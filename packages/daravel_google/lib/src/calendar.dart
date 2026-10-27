import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'credentials.dart';

/// Who Google emails about a change (`sendUpdates`).
enum SendUpdates {
  /// Every guest, as `CalendarVm.php` asks.
  all,

  /// Guests outside the calendar's domain only.
  externalOnly,

  /// No one.
  none,
}

/// The start or end of an event: a time, or a whole day.
final class EventTime {
  /// At [dateTime]. A UTC [dateTime] is an instant; any other is a wall
  /// clock time in [timeZone] (an IANA name such as `Asia/Makassar`), or
  /// in the calendar client's time zone when [timeZone] is null.
  const EventTime(this.dateTime, {this.timeZone}) : allDay = false;

  /// The whole day of [date] (its year, month and day).
  const EventTime.date(DateTime date)
    : dateTime = date,
      timeZone = null,
      allDay = true;

  /// Google's `{date}` or `{dateTime, timeZone}`.
  factory EventTime.fromJson(Map<String, Object?> json) {
    if (json['date'] case final String date) {
      return EventTime.date(DateTime.parse(date));
    }
    return EventTime(
      DateTime.parse(json['dateTime']! as String),
      timeZone: json['timeZone'] as String?,
    );
  }

  final DateTime dateTime;
  final String? timeZone;
  final bool allDay;

  /// Google's JSON, with [defaultTimeZone] for a wall clock time without
  /// its own.
  Map<String, Object?> toJson(String defaultTimeZone) {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = dateTime;
    final date =
        '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-'
        '${two(d.day)}';
    if (allDay) {
      return {'date': date};
    }
    if (d.isUtc) {
      return {'dateTime': d.toIso8601String(), 'timeZone': ?timeZone};
    }
    return {
      'dateTime': '${date}T${two(d.hour)}:${two(d.minute)}:${two(d.second)}',
      'timeZone': timeZone ?? defaultTimeZone,
    };
  }
}

/// A guest of an event.
final class EventAttendee {
  const EventAttendee(
    this.email, {
    this.displayName,
    this.optional = false,
    this.responseStatus,
  });

  factory EventAttendee.fromJson(Map<String, Object?> json) => EventAttendee(
    json['email']! as String,
    displayName: json['displayName'] as String?,
    optional: json['optional'] == true,
    responseStatus: json['responseStatus'] as String?,
  );

  final String email;
  final String? displayName;
  final bool optional;

  /// Google's answer: `needsAction`, `accepted`, `declined`, `tentative`.
  final String? responseStatus;

  Map<String, Object?> toJson() => {
    'email': email,
    'displayName': ?displayName,
    if (optional) 'optional': true,
  };
}

/// An event of Google Calendar v3: what to send ([CalendarEvent.new]) and
/// what Google answered ([CalendarEvent.fromJson], with [json] kept whole).
final class CalendarEvent {
  /// An event to create, replace or patch. Null fields are left out, so a
  /// patch changes only what is set. [meet] asks Google for a new Google
  /// Meet link.
  CalendarEvent({
    this.summary,
    this.description,
    this.location,
    this.start,
    this.end,
    this.attendees,
    this.meet = false,
  }) : id = null,
       json = const {};

  CalendarEvent.fromJson(this.json)
    : id = json['id'] as String?,
      summary = json['summary'] as String?,
      description = json['description'] as String?,
      location = json['location'] as String?,
      start = switch (json['start']) {
        final Map<String, Object?> time => EventTime.fromJson(time),
        _ => null,
      },
      end = switch (json['end']) {
        final Map<String, Object?> time => EventTime.fromJson(time),
        _ => null,
      },
      attendees = switch (json['attendees']) {
        final List<Object?> list => [
          for (final item in list)
            if (item is Map<String, Object?>) EventAttendee.fromJson(item),
        ],
        _ => null,
      },
      meet = false;

  final String? id;
  final String? summary;
  final String? description;
  final String? location;
  final EventTime? start;
  final EventTime? end;
  final List<EventAttendee>? attendees;
  final bool meet;

  /// Google's answer as it came (empty for an event built to send).
  final Map<String, Object?> json;

  /// `confirmed`, `tentative` or `cancelled`.
  String? get status => json['status'] as String?;

  /// The event in Google Calendar's web page.
  String? get htmlLink => json['htmlLink'] as String?;

  /// The Google Meet link: the conference's video entry point, or
  /// `hangoutLink`. Null while Google is still creating it (see
  /// [conferenceStatus]) or when the event has none.
  String? get meetUrl {
    if (json['conferenceData'] case {
      'entryPoints': final List<Object?> points,
    }) {
      for (final point in points) {
        if (point case {'entryPointType': 'video', 'uri': final String uri}) {
          return uri;
        }
      }
    }
    return json['hangoutLink'] as String?;
  }

  /// `pending`, `success` or `failure` after [meet] asked for a link.
  String? get conferenceStatus => switch (json['conferenceData']) {
    {'createRequest': {'status': {'statusCode': final String code}}} => code,
    _ => null,
  };

  static final Random _random = Random.secure();

  /// The request body.
  Map<String, Object?> toJson(String timeZone) => {
    'summary': ?summary,
    'description': ?description,
    'location': ?location,
    if (start != null) 'start': start!.toJson(timeZone),
    if (end != null) 'end': end!.toJson(timeZone),
    if (attendees != null)
      'attendees': [for (final attendee in attendees!) attendee.toJson()],
    if (meet)
      'conferenceData': {
        'createRequest': {
          // Google creates one conference per request id.
          'requestId': [for (var i = 0; i < 16; i++) _random.nextInt(256)]
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          'conferenceSolutionKey': {'type': 'hangoutsMeet'},
        },
      },
  };
}

/// One calendar of Google Calendar v3: create, read, list, change and
/// delete events, with guests and Google Meet links.
///
/// ```dart
/// final calendar = GoogleCalendar(credentials, timeZone: 'Asia/Makassar');
/// final event = await calendar.create(CalendarEvent(
///   summary: 'Matematika XI',
///   start: EventTime(DateTime(2026, 10, 28, 7, 30)),
///   end: EventTime(DateTime(2026, 10, 28, 9)),
///   attendees: [EventAttendee('siswa@sekolah.sch.id', displayName: 'Siswa')],
///   meet: true,
/// ));
/// print(event.meetUrl);
/// ```
///
/// Inside an application it sends through the application's HTTP client
/// (so `Http.fake()` stubs it); elsewhere through one of its own.
final class GoogleCalendar {
  GoogleCalendar(
    this.credentials, {
    this.calendarId = 'primary',
    this.timeZone = 'UTC',
    HttpClientFactory? http,
    this.timeout = const Duration(seconds: 10),
  }) : _http = GoogleHttp(http);

  static const String baseUrl = 'https://www.googleapis.com/calendar/v3';

  final GoogleCredentials credentials;

  /// `primary` (the user's own) or a calendar's id, such as its email.
  final String calendarId;

  /// The time zone of [EventTime]s given as wall clock times.
  final String timeZone;
  final Duration timeout;
  final GoogleHttp _http;

  String _events([String? id]) =>
      '$baseUrl/calendars/${Uri.encodeComponent(calendarId)}/events'
      '${id == null ? '' : '/${Uri.encodeComponent(id)}'}';

  Future<ClientResponse> _send(
    String action,
    String method,
    String url, {
    Map<String, Object?>? query,
    Object? json,
    Set<int> alsoFine = const {},
  }) async {
    final response = await _http.factory
        .request()
        .withToken(await credentials.accessToken())
        .acceptJson()
        .timeout(timeout)
        .send(method, url, query: query, json: json);
    if (!response.successful && !alsoFine.contains(response.status)) {
      throw GoogleException.from(action, response);
    }
    return response;
  }

  /// Creates [event] and returns it as Google stored it (with its [id] and,
  /// when [CalendarEvent.meet] was set, its Meet link).
  Future<CalendarEvent> create(
    CalendarEvent event, {
    SendUpdates sendUpdates = SendUpdates.all,
  }) async => CalendarEvent.fromJson(
    (await _send(
      'Create the event',
      'POST',
      _events(),
      query: {'conferenceDataVersion': '1', 'sendUpdates': sendUpdates.name},
      json: event.toJson(timeZone),
    )).jsonMap(),
  );

  /// The event [id].
  Future<CalendarEvent> get(String id) async => CalendarEvent.fromJson(
    (await _send('Get event $id', 'GET', _events(id))).jsonMap(),
  );

  /// Events from [from] to [to] (each occurrence of a recurring one), in
  /// order of their start, matching [query] when given, up to [max].
  Future<List<CalendarEvent>> list({
    DateTime? from,
    DateTime? to,
    String? query,
    int max = 250,
  }) async {
    final events = <CalendarEvent>[];
    String? page;
    do {
      final reply = (await _send(
        'List events',
        'GET',
        _events(),
        query: {
          'singleEvents': 'true',
          'orderBy': 'startTime',
          'maxResults': '${min(max - events.length, 2500)}',
          if (from != null) 'timeMin': from.toUtc().toIso8601String(),
          if (to != null) 'timeMax': to.toUtc().toIso8601String(),
          'q': ?query,
          'pageToken': ?page,
        },
      )).jsonMap();
      for (final item in reply['items'] as List<Object?>? ?? const []) {
        if (item is Map<String, Object?>) {
          events.add(CalendarEvent.fromJson(item));
        }
      }
      page = reply['nextPageToken'] as String?;
    } while (page != null && events.length < max);
    return events;
  }

  /// Changes only the fields set in [changes] (PATCH). Setting
  /// [CalendarEvent.meet] adds a new Meet link; leaving it out keeps the
  /// existing one.
  Future<CalendarEvent> patch(
    String id,
    CalendarEvent changes, {
    SendUpdates sendUpdates = SendUpdates.all,
  }) async => CalendarEvent.fromJson(
    (await _send(
      'Update event $id',
      'PATCH',
      _events(id),
      query: {'conferenceDataVersion': '1', 'sendUpdates': sendUpdates.name},
      json: changes.toJson(timeZone),
    )).jsonMap(),
  );

  /// Replaces event [id] with [event] (PUT), as google/apiclient's
  /// `events->update` does: fields left out are cleared, guests and the
  /// Meet link included. [patch] is usually what you want.
  Future<CalendarEvent> replace(
    String id,
    CalendarEvent event, {
    SendUpdates sendUpdates = SendUpdates.all,
  }) async => CalendarEvent.fromJson(
    (await _send(
      'Replace event $id',
      'PUT',
      _events(id),
      query: {'conferenceDataVersion': '1', 'sendUpdates': sendUpdates.name},
      json: event.toJson(timeZone),
    )).jsonMap(),
  );

  /// Deletes event [id]. An event already deleted (`410 Gone`) is fine.
  Future<void> delete(
    String id, {
    SendUpdates sendUpdates = SendUpdates.all,
  }) async {
    await _send(
      'Delete event $id',
      'DELETE',
      _events(id),
      query: {'sendUpdates': sendUpdates.name},
      alsoFine: const {410},
    );
  }
}
