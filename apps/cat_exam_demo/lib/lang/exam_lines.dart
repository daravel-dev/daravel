import 'ui_lines.dart';

/// The application's translation lines, registered with `withTranslations` in
/// `bootstrap/app.dart`. English is the default; `?lang=id` or an
/// `Accept-Language: id` header switches a request to Indonesian.
const Map<String, Map<String, Object?>> examLines = {
  'en': {
    'ui': uiLinesEn,
    'exam': {
      'credentials_required': 'NIK and exam number are required.',
      'token_missing': 'The exam session token is missing.',
      'session_invalid_or_expired':
          'The exam session is invalid or has expired.',
      'session_invalid': 'The exam session is invalid.',
      'session_not_found': 'Exam session not found.',
      'answer_required': 'question_id (1..:count) and selected_option (A..E) are required and must be valid.',
      'answers_array': 'answers must be an array of answers.',
      'session_id_required': 'A session ID is required.',
      'session_missing': 'Session not found.',
      'not_submitted': 'This exam session has not been finished yet.',
      'nik_required': 'NIK is required.',
      'device_reset': 'The device lock for NIK [:nik] was reset. The candidate can log in on a new computer.',
      'device_locked':
          'The exam session for NIK :nik is active on another device [:device]. '
          'Each candidate is locked to one physical device to prevent cheating. '
          'Ask the proctor for help if your device has a technical problem.',
      'invalid_device': 'Invalid device ID.',
      'not_registered': 'NIK [:nik] or exam number [:number] is not registered for this exam.',
      'completed': 'Your exam is finished and has been scored.',
      'time_up_submitted': 'Your exam time is up and your answer sheet was submitted automatically.',
      'resumed': 'Exam session resumed on the same device.',
      'created': 'A new exam session was created and this device is locked.',
      'candidate_not_found': 'No candidate with NIK [:nik] was found.',
      'already_submitted': 'The exam session is finished and submitted. Answers can no longer be changed.',
      'expired_at':
          'Your exam time ended at :time. New answers cannot be saved.',
      'invalid_option': 'Answer option [:option] is not valid. Allowed options: A, B, C, D, E.',
      'unknown_question':
          'Question [:id] is not in the question bank (1..:count).',
      'batch_submitted':
          'The exam session is finished. The batch of answers was rejected.',
      'batch_expired':
          'The exam time is up. The batch of answers was rejected.',
      'candidate_fallback': 'Candidate :id',
    },
  },
  'id': {
    'ui': uiLinesId,
    'exam': {
      'credentials_required': 'NIK dan Nomor Peserta wajib diisi.',
      'token_missing': 'Token sesi ujian tidak disertakan.',
      'session_invalid_or_expired':
          'Sesi ujian tidak valid atau telah kedaluwarsa.',
      'session_invalid': 'Sesi ujian tidak valid.',
      'session_not_found': 'Sesi ujian tidak ditemukan.',
      'answer_required': 'question_id (1..:count) dan selected_option (A..E) wajib diisi dengan benar.',
      'answers_array': 'answers harus berupa array jawaban.',
      'session_id_required': 'ID Sesi diperlukan.',
      'session_missing': 'Sesi tidak ditemukan.',
      'not_submitted': 'Sesi ujian ini belum selesai dikerjakan.',
      'nik_required': 'NIK wajib diisi.',
      'device_reset': 'Kunci perangkat untuk NIK [:nik] berhasil direset. Peserta dapat login di komputer baru.',
      'device_locked':
          'Sesi ujian NIK :nik sedang aktif di perangkat lain [:device]. '
          'Sistem CAT mengunci 1 peserta hanya pada 1 perangkat fisik untuk mencegah kecurangan. '
          'Hubungi proctor/pengawas ruangan jika perangkat Anda mengalami kendala teknis.',
      'invalid_device': 'Device ID tidak valid.',
      'not_registered': 'NIK [:nik] atau Nomor Peserta [:number] tidak terdaftar dalam sistem seleksi.',
      'completed': 'Ujian Anda telah selesai dikerjakan dan telah dinilai.',
      'time_up_submitted': 'Waktu ujian Anda telah habis dan lembar jawaban dikumpulkan otomatis.',
      'resumed': 'Sesi ujian berhasil dipulihkan dari perangkat yang sama.',
      'created': 'Sesi ujian baru berhasil dibuat dan perangkat dikunci.',
      'candidate_not_found': 'Peserta dengan NIK [:nik] tidak ditemukan.',
      'already_submitted': 'Sesi ujian telah selesai dikerjakan dan dikumpulkan. Jawaban tidak dapat diubah lagi.',
      'expired_at': 'Waktu ujian Anda telah habis pada :time. Jawaban baru tidak dapat disimpan.',
      'invalid_option': 'Pilihan jawaban [:option] tidak valid. Opsi yang diperbolehkan: A, B, C, D, E.',
      'unknown_question':
          'Nomor soal [:id] tidak ditemukan dalam bank soal (1..:count).',
      'batch_submitted':
          'Sesi ujian telah selesai dikerjakan. Batch jawaban ditolak.',
      'batch_expired': 'Waktu ujian telah habis. Batch jawaban ditolak.',
      'candidate_fallback': 'Peserta :id',
    },
  },
};
