import 'package:cat_exam_demo/app/models/candidate.dart';
import 'package:daravel/daravel.dart';

/// Seeds default test candidates for the CAT TKA simulation.
final class CandidateSeeder extends Seeder {
  const CandidateSeeder();

  @override
  Future<void> run() async {
    final defaultCandidates = [
      {
        'nik': '3201011203950001',
        'exam_number': 'TKA-2026-001',
        'name': 'Budi Santoso, S.Kom.',
        'status': 'registered',
      },
      {
        'nik': '3201015508960002',
        'exam_number': 'TKA-2026-002',
        'name': 'Siti Rahmawati, S.AP.',
        'status': 'registered',
      },
      {
        'nik': '3201012211940003',
        'exam_number': 'TKA-2026-003',
        'name': 'Ahmad Fauzi, S.T.',
        'status': 'registered',
      },
      {
        'nik': '3201014405970004',
        'exam_number': 'TKA-2026-004',
        'name': 'Dewi Sartika, S.E.',
        'status': 'registered',
      },
      {
        'nik': '3201011908930005',
        'exam_number': 'TKA-2026-005',
        'name': 'Hendra Wijaya, S.H.',
        'status': 'registered',
      },
    ];

    for (final cand in defaultCandidates) {
      final existing = await Candidate.where('nik', cand['nik']).first();
      if (existing == null) {
        await Candidate.create(cand);
      }
    }
  }
}
