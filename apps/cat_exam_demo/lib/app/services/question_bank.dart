import 'package:daravel/daravel.dart';

import 'question_bank_en.dart';

/// In-memory master Question Bank for CAT CPNS / TKA.
///
/// Kept in-memory for 0ms latency and high-throughput question delivery
/// without stressing database read-replicas during 100k+ candidate surges.
final class QuestionData {
  const QuestionData({
    required this.id,
    required this.category,
    required this.questionText,
    required this.options,
    this.correctOption,
    this.weight = 5,
  });

  final int id;
  final String category; // 'TWK', 'TIU', 'TKP'
  final String questionText;
  final List<OptionData> options;
  final String? correctOption; // 'A'..'E' for TWK/TIU
  final int weight;

  Map<String, Object?> toPublicJson() => {
    'id': id,
    'category': category,
    'question_text': questionText,
    'options': options.map((o) => o.toPublicJson()).toList(),
    'weight': weight,
  };

  Map<String, Object?> toDbJson() => {
    'id': id,
    'category': category,
    'question_text': questionText,
    'options': options.map((o) => o.toJson()).toList(),
    'correct_option': correctOption,
    'weight': weight,
  };
}

final class OptionData {
  const OptionData({required this.id, required this.text, required this.score});

  final String id; // 'A'..'E'
  final String text;
  final int score; // 0 or 5 for TWK/TIU; 1..5 for TKP

  Map<String, Object?> toPublicJson() => {'id': id, 'text': text};

  Map<String, Object?> toJson() => {'id': id, 'text': text, 'score': score};
}

abstract final class QuestionBank {
  /// The questions in the current locale (`App.locale`): Indonesian for `id`,
  /// English otherwise. Both banks share ids, answer keys and scores.
  static List<QuestionData> get defaultQuestions => forLocale(App.locale);

  static List<QuestionData> forLocale(String locale) =>
      locale == 'id' ? indonesian : englishQuestions;

  static const List<QuestionData> indonesian = [
    // ==========================================
    // TWK (Tes Wawasan Kebangsaan) - 5 Questions
    // ==========================================
    QuestionData(
      id: 1,
      category: 'TWK',
      questionText: 'Pengamalan Pancasila sila ke-3 "Persatuan Indonesia" dalam era transformasi digital di lingkungan birokrasi pemerintahan daerah paling tepat diwujudkan melalui...',
      correctOption: 'C',
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Membatasi komunikasi kedinasan hanya antar-pegawai yang berasal dari daerah yang sama.',
          score: 0,
        ),
        OptionData(
          id: 'B',
          text: 'Menolak adopsi aplikasi nasional demi menjaga kemandirian sistem teknologi kabupaten sendiri.',
          score: 0,
        ),
        OptionData(
          id: 'C',
          text: 'Mengintegrasikan layanan digital lintas instansi untuk mempermudah akses seluruh lapisan masyarakat tanpa diskriminasi.',
          score: 5,
        ),
        OptionData(
          id: 'D',
          text: 'Membuat grup media sosial eksklusif untuk ASN berprestasi di tingkat kabupaten.',
          score: 0,
        ),
        OptionData(
          id: 'E',
          text: 'Mengutamakan penyerapan anggaran IT daerah sebelum mengevaluasi dampak persatuan sosial.',
          score: 0,
        ),
      ],
    ),
    QuestionData(
      id: 2,
      category: 'TWK',
      questionText: 'Berdasarkan Pasal 24C ayat (1) UUD 1945, Mahkamah Konstitusi berwenang mengadili pada tingkat pertama dan terakhir yang putusannya bersifat final untuk...',
      correctOption: 'B',
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Menguji peraturan pemerintah terhadap undang-undang dan memutus sengketa pilkada.',
          score: 0,
        ),
        OptionData(
          id: 'B',
          text: 'Menguji undang-undang terhadap UUD 1945 dan memutus sengketa kewenangan lembaga negara yang kewenangannya diberikan oleh UUD 1945.',
          score: 5,
        ),
        OptionData(
          id: 'C',
          text: 'Memberikan pertimbangan hukum kepada Presiden terkait grasi dan rehabilitasi terpidana korupsi.',
          score: 0,
        ),
        OptionData(
          id: 'D',
          text: 'Mengangkat hakim agung serta mengawasi kode etik peradilan umum di tingkat daerah.',
          score: 0,
        ),
        OptionData(
          id: 'E',
          text: 'Menetapkan rancangan undang-undang APBD kabupaten yang mengalami kebuntuan politik.',
          score: 0,
        ),
      ],
    ),
    QuestionData(
      id: 3,
      category: 'TWK',
      questionText: 'Sesuai UU No. 23 Tahun 2019 tentang Pengelolaan Sumber Daya Nasional untuk Pertahanan Negara, salah satu nilai dasar Bela Negara yang wajib diinternalisasi oleh setiap aparatur sipil adalah...',
      correctOption: 'D',
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Kesiapan memegang senjata api dalam tugas kedinasan sehari-hari.',
          score: 0,
        ),
        OptionData(
          id: 'B',
          text: 'Kepatuhan mutlak terhadap instruksi politik kepala daerah terpilih.',
          score: 0,
        ),
        OptionData(
          id: 'C',
          text: 'Mengabaikan kepentingan keluarga demi penugasan lembur yang tidak terencana.',
          score: 0,
        ),
        OptionData(
          id: 'D',
          text: 'Setia pada Pancasila sebagai ideologi negara dan rela berkorban untuk bangsa dan negara.',
          score: 5,
        ),
        OptionData(
          id: 'E',
          text:
              'Menolak bantuan internasional dalam penanganan bencana daerah.',
          score: 0,
        ),
      ],
    ),
    QuestionData(
      id: 4,
      category: 'TWK',
      questionText: 'Prinsip Bhinneka Tunggal Ika dalam penyelenggaraan pelayanan publik di kantor dinas kabupaten menekankan bahwa ASN wajib...',
      correctOption: 'A',
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Memberikan standar pelayanan yang setara, adil, dan profesional tanpa membedakan suku, agama, ras, maupun latar belakang politik warga.',
          score: 5,
        ),
        OptionData(
          id: 'B',
          text: 'Memprioritaskan pemohon izin yang berasal dari marga atau garis keturunan yang sama dengan pimpinan dinas.',
          score: 0,
        ),
        OptionData(
          id: 'C',
          text: 'Menyeragamkan seluruh tradisi lokal warga pemohon menjadi satu format budaya dominan di kantor.',
          score: 0,
        ),
        OptionData(
          id: 'D',
          text: 'Menghentikan layanan publik saat ada perayaan adat sebagian kelompok masyarakat.',
          score: 0,
        ),
        OptionData(
          id: 'E',
          text: 'Mengalokasikan loket pelayanan terpisah berdasarkan afiliasi organisasi massa.',
          score: 0,
        ),
      ],
    ),
    QuestionData(
      id: 5,
      category: 'TWK',
      questionText: 'Penulisan kalimat dinas yang baku, efektif, dan sesuai Pedoman Umum Ejaan Bahasa Indonesia (EYD V) berikut adalah...',
      correctOption: 'E',
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Pemerintah daerah merencanakan daripada pembangunan infrastruktur jalan antar-kecamatan.',
          score: 0,
        ),
        OptionData(
          id: 'B',
          text: 'Bagi seluruh daripada para peserta ujian diharapkan hadir sebelum jam ujian dimulai.',
          score: 0,
        ),
        OptionData(
          id: 'C',
          text: 'Surat keputusan ini dibuat guna untuk mengesahkan standarisasi ujian seleksi kabupaten.',
          score: 0,
        ),
        OptionData(
          id: 'D',
          text: 'Dalam rapat itu membicarakan tentang peningkatan efisiensi anggaran belanja pegawai daerah.',
          score: 0,
        ),
        OptionData(
          id: 'E',
          text: 'Pemerintah kabupaten menetapkan standardisasi sistem ujian berbasis komputer guna meningkatkan akuntabilitas seleksi.',
          score: 5,
        ),
      ],
    ),

    // ==========================================
    // TIU (Tes Inteligensia Umum) - 5 Questions
    // ==========================================
    QuestionData(
      id: 6,
      category: 'TIU',
      questionText: 'KENDARAAN : BENSIN = MANUSIA : ...',
      correctOption: 'B',
      weight: 5,
      options: [
        OptionData(id: 'A', text: 'AIR', score: 0),
        OptionData(id: 'B', text: 'MAKANAN', score: 5),
        OptionData(id: 'C', text: 'PAKAIAN', score: 0),
        OptionData(id: 'D', text: 'JALAN', score: 0),
        OptionData(id: 'E', text: 'RUMAH', score: 0),
      ],
    ),
    QuestionData(
      id: 7,
      category: 'TIU',
      questionText: 'Premis 1: Semua ASN berintegritas menolak segala bentuk gratifikasi.\nPremis 2: Sebagian pejabat dinas di Kabupaten X adalah ASN berintegritas.\nKesimpulan yang sah dan logis adalah...',
      correctOption: 'C',
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Semua pejabat dinas di Kabupaten X menolak segala bentuk gratifikasi.',
          score: 0,
        ),
        OptionData(
          id: 'B',
          text: 'Sebagian pejabat dinas di Kabupaten X menerima bentuk gratifikasi kedinasan.',
          score: 0,
        ),
        OptionData(
          id: 'C',
          text: 'Sebagian pejabat dinas di Kabupaten X menolak segala bentuk gratifikasi.',
          score: 5,
        ),
        OptionData(
          id: 'D',
          text: 'Tidak ada pejabat dinas di Kabupaten X yang menolak gratifikasi.',
          score: 0,
        ),
        OptionData(
          id: 'E',
          text: 'Pejabat dinas di Kabupaten X bukan merupakan aparatur sipil negara.',
          score: 0,
        ),
      ],
    ),
    QuestionData(
      id: 8,
      category: 'TIU',
      questionText: 'Tentukan angka berikutnya pada deret bilangan berikut:\n3, 7, 15, 31, 63, ...',
      correctOption: 'D',
      weight: 5,
      options: [
        OptionData(id: 'A', text: '95', score: 0),
        OptionData(id: 'B', text: '112', score: 0),
        OptionData(id: 'C', text: '124', score: 0),
        OptionData(id: 'D', text: '127', score: 5),
        OptionData(id: 'E', text: '135', score: 0),
      ],
    ),
    QuestionData(
      id: 9,
      category: 'TIU',
      questionText: 'Sebuah tim pengembang sistem CAT dapat menyelesaikan verifikasi berkas 1.200 peserta dalam waktu 4 jam menggunakan 6 server. Jika jumlah server ditambah menjadi 10 server dengan spesifikasi yang sama, berapa waktu yang dibutuhkan untuk memverifikasi 3.000 berkas peserta?',
      correctOption: 'A',
      weight: 5,
      options: [
        OptionData(id: 'A', text: '6 jam', score: 5),
        OptionData(id: 'B', text: '5 jam', score: 0),
        OptionData(id: 'C', text: '7,5 jam', score: 0),
        OptionData(id: 'D', text: '8 jam', score: 0),
        OptionData(id: 'E', text: '4,5 jam', score: 0),
      ],
    ),
    QuestionData(
      id: 10,
      category: 'TIU',
      questionText: 'Lima kepala bidang (A, B, C, D, E) memaparkan hasil evaluasi program kabupaten secara berurutan. B memaparkan tepat sebelum C. D memaparkan setelah A namun sebelum B. E memaparkan di urutan paling awal. Siapakah yang memaparkan di urutan ketiga?',
      correctOption: 'B',
      weight: 5,
      options: [
        OptionData(id: 'A', text: 'A', score: 0),
        OptionData(id: 'B', text: 'D', score: 5),
        OptionData(id: 'C', text: 'B', score: 0),
        OptionData(id: 'D', text: 'C', score: 0),
        OptionData(id: 'E', text: 'E', score: 0),
      ],
    ),

    // ==========================================
    // TKP (Tes Karakteristik Pribadi) - 5 Questions
    // (Graded on a scale of 1 to 5)
    // ==========================================
    QuestionData(
      id: 11,
      category: 'TKP',
      questionText: 'Seorang warga lansia mendatangi loket pelayanan kabupaten tempat Anda bertugas dan tampak kebingungan mengoperasikan anjungan digital pendaftaran nomor antrean. Sikap Anda adalah...',
      correctOption: null, // TKP has no single correct answer; 1..5 scale
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Mendatangi warga tersebut dengan ramah, memandu pengisian di layar secara sabar, dan menjelaskan alur berikutnya hingga warga merasa tenang.',
          score: 5,
        ),
        OptionData(
          id: 'B',
          text: 'Meminta petugas keamanan (satpam) loket untuk membantu warga tersebut karena loket Anda sedang antre.',
          score: 3,
        ),
        OptionData(
          id: 'C',
          text: 'Menyuruh warga tersebut menunggu keluarga atau pendamping yang lebih mengerti penggunaan smartphone.',
          score: 2,
        ),
        OptionData(
          id: 'D',
          text: 'Menyapa warga dari balik loket dan membimbing melalui pengeras suara agar warga lain juga mendengar.',
          score: 4,
        ),
        OptionData(
          id: 'E',
          text: 'Membiarkan warga mencoba terlebih dahulu agar belajar mandiri menggunakan fasilitas publik modern.',
          score: 1,
        ),
      ],
    ),
    QuestionData(
      id: 12,
      category: 'TKP',
      questionText: 'Terjadi hambatan teknis pada sinkronisasi data antar-bidang di dinas Anda yang berpotensi menunda pelaporan akuntabilitas ke tingkat provinsi esok hari. Respons Anda adalah...',
      correctOption: null,
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Menyalahkan bidang pengelola server data yang dianggap lamban mengantisipasi kendala format file.',
          score: 1,
        ),
        OptionData(
          id: 'B',
          text: 'Menginisiasi pertemuan kilat bersama tim teknis kedua bidang, memetakan akar kendala, dan berkolaborasi lembur bersama menuntaskan sinkronisasi.',
          score: 5,
        ),
        OptionData(
          id: 'C',
          text: 'Menyusun laporan penjelasan alasan kendala kepada provinsi agar dinas mendapatkan perpanjangan tenggat waktu.',
          score: 3,
        ),
        OptionData(
          id: 'D',
          text: 'Fokus hanya mengerjakan data di bidang saya sendiri dan menyerahkan data bidang lain kepada atasan.',
          score: 2,
        ),
        OptionData(
          id: 'E',
          text: 'Menghubungi rekan bidang lain untuk menawarkan bantuan konversi format manual jika bidang mereka kewalahan.',
          score: 4,
        ),
      ],
    ),
    QuestionData(
      id: 13,
      category: 'TKP',
      questionText: 'Pemerintah kabupaten baru saja meluncurkan platform digital terpadu berbasis Dart AOT (Daravel) untuk meningkatkan transparansi seleksi dan kecepatan layanan. Beberapa rekan kerja senior merasa enggan beradaptasi dan ingin tetap menggunakan cara manual. Tindakan Anda...',
      correctOption: null,
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Mengajak rekan-rekan senior berdiskusi santai, memperlihatkan kemudahan dan efisiensi waktu sistem baru, serta proaktif mendampingi mereka saat proses input berlangsung.',
          score: 5,
        ),
        OptionData(
          id: 'B',
          text: 'Melaporkan ketidakmauan rekan senior ke Badan Kepegawaian Daerah agar diberikan teguran disiplin.',
          score: 2,
        ),
        OptionData(
          id: 'C',
          text: 'Mengambil alih seluruh tugas digital rekan senior tersebut secara sepihak agar pekerjaan kantor tetap selesai cepat.',
          score: 3,
        ),
        OptionData(
          id: 'D',
          text: 'Membuatkan buku panduan ringkas bergambar dan membagikannya di grup WhatsApp kantor agar bisa dibaca saat luang.',
          score: 4,
        ),
        OptionData(
          id: 'E',
          text: 'Membiarkan saja karena senioritas harus dihormati dan menunggu sampai mereka berinisiatif belajar sendiri.',
          score: 1,
        ),
      ],
    ),
    QuestionData(
      id: 14,
      category: 'TKP',
      questionText: 'Saat Anda bersiap pulang tepat waktu untuk menghadiri acara ulang tahun anak Anda, pimpinan dinas memberikan tugas darurat verifikasi dokumen TKA yang harus selesai malam ini juga. Apa yang Anda lakukan?',
      correctOption: null,
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Menolak tugas tersebut secara langsung karena jam kerja kedinasan telah usai dan hak keluarga dilindungi undang-undang.',
          score: 1,
        ),
        OptionData(
          id: 'B',
          text: 'Menerima tugas darurat dengan penuh tanggung jawab, menghubungi keluarga untuk memberikan pengertian, dan menuntaskan verifikasi dengan teliti sebelum pulang.',
          score: 5,
        ),
        OptionData(
          id: 'C',
          text: 'Membawa dokumen tersebut pulang ke rumah dan mengerjakannya larut malam setelah pesta keluarga selesai.',
          score: 4,
        ),
        OptionData(
          id: 'D',
          text: 'Meminta tolong kepada rekan kerja yang masih lajang untuk menggantikan tugas saya dengan imbalan mentraktir esok hari.',
          score: 3,
        ),
        OptionData(
          id: 'E',
          text: 'Mengerjakan separuh dokumen dengan tergesa-gesa agar sempat menghadiri acara keluarga sebelum malam larut.',
          score: 2,
        ),
      ],
    ),
    QuestionData(
      id: 15,
      category: 'TKP',
      questionText: 'Di grup percakapan internal staf dinas, seorang rekan kerja mengunggah opini yang provokatif dan mendiskreditkan dasar negara serta menyerukan penolakan terhadap pemilu daerah. Sikap Anda adalah...',
      correctOption: null,
      weight: 5,
      options: [
        OptionData(
          id: 'A',
          text: 'Segera membalas di grup dengan kata-kata kasar untuk membela pimpinan daerah.',
          score: 1,
        ),
        OptionData(
          id: 'B',
          text: 'Mengingatkan secara santun namun tegas di grup bahwa ASN terikat sumpah setia pada Pancasila dan grup kedinasan bukan wadah penyebaran hoaks/isu SARA, serta melaporkan ke atasan pembina.',
          score: 5,
        ),
        OptionData(
          id: 'C',
          text: 'Langsung keluar dari grup kedinasan tersebut agar tidak terlibat perdebatan.',
          score: 2,
        ),
        OptionData(
          id: 'D',
          text: 'Mengirim pesan pribadi (japri) kepada yang bersangkutan untuk menghapus unggahan tersebut agar tidak diketahui pihak berwajib.',
          score: 4,
        ),
        OptionData(
          id: 'E',
          text: 'Menyimpan tangkapan layar (screenshot) dan menyebarkannya ke media sosial agar rekan tersebut mendapat sanksi sosial.',
          score: 3,
        ),
      ],
    ),
  ];
}
