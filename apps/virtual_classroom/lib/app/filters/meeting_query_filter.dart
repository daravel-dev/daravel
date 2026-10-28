import 'package:daravel_teorion/daravel_teorion.dart';

import '../models/meeting.dart';

/// `GET /api/meetings?q=algebra&status=published&classroom_id=2&date=2026-11-02&sort=-starts_at`
final class MeetingQueryFilter extends QueryFilter<Meeting> {
  const MeetingQueryFilter();

  @override
  Map<String, Filter> get filters => {
    'search': Filter.multiLike(['name', 'description']).alias('q'),
    'status': Filter.enum_('status', const ['draft', 'published']),
    'classroom_id': Filter.exact(),
    'date': Filter.date('starts_at'),
  };

  @override
  List<String> get allowedSorts => const ['starts_at', 'name'];

  @override
  List<String> get defaultSort => const ['starts_at'];
}
