import 'dart:convert';

import 'package:daravel/daravel.dart'
    show daravelFaviconDataUri, daravelLogoDataUri;

/// Renders the Interactive Virtual Classroom Single Page Web Application.
String virtualClassroomPage({
  required String appName,
  required String environment,
  required String dartVersion,
  required String frameworkVersion,
  required String requestId,
}) {
  final name = htmlEscape.convert(appName);

  return '''
<!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name - Showcase LiveKit, Google Calendar & Spatie Permissions</title>
<link rel="icon" type="image/png" href="$daravelFaviconDataUri">
<style>
  :root {
    --primary: #4f46e5;
    --primary-dark: #3730a3;
    --primary-light: #6366f1;
    --accent: #06b6d4;
    --success: #10b981;
    --warning: #f59e0b;
    --danger: #ef4444;
    --bg: #0f172a;
    --card-bg: #1e293b;
    --card-hover: #26354a;
    --border: #334155;
    --text: #f8fafc;
    --text-muted: #94a3b8;
    --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --shadow: 0 4px 6px -1px rgb(0 0 0 / 0.3), 0 2px 4px -2px rgb(0 0 0 / 0.3);
    --shadow-lg: 0 10px 25px -5px rgb(0 0 0 / 0.5), 0 8px 10px -6px rgb(0 0 0 / 0.5);
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    display: flex;
    flex-direction: column;
  }

  /* Header */
  .top-header {
    background: rgba(15, 23, 42, 0.95);
    backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--border);
    padding: 12px 24px;
    position: sticky;
    top: 0;
    z-index: 40;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 16px;
  }
  .brand-group {
    display: flex;
    align-items: center;
    gap: 14px;
  }
  .brand-logo {
    width: 36px;
    height: 36px;
    background: white;
    border-radius: 8px;
    padding: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .brand-title {
    font-size: 17px;
    font-weight: 700;
    letter-spacing: -0.3px;
    color: #fff;
  }
  .brand-sub {
    font-size: 11.5px;
    color: var(--text-muted);
  }

  .nav-actions {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }

  /* User Switcher Pill */
  .user-switcher {
    display: flex;
    align-items: center;
    gap: 8px;
    background: #090e1a;
    border: 1px solid var(--border);
    border-radius: 999px;
    padding: 4px 6px 4px 14px;
    font-size: 13px;
  }
  .user-role-badge {
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
  }
  .role-teacher { background: #4338ca; color: #e0e7ff; }
  .role-student { background: #065f46; color: #a7f3d0; }
  .role-outsider { background: #7f1d1d; color: #fecaca; }

  /* Buttons */
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    border-radius: 8px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    transition: all 0.15s ease;
    text-decoration: none;
  }
  .btn-primary { background: var(--primary); color: white; }
  .btn-primary:hover { background: var(--primary-light); }
  .btn-primary:disabled { opacity: 0.6; cursor: not-allowed; }
  .btn-success { background: var(--success); color: white; }
  .btn-success:hover { filter: brightness(1.1); }
  .btn-warning { background: var(--warning); color: #000; }
  .btn-warning:hover { filter: brightness(1.1); }
  .btn-danger { background: var(--danger); color: white; }
  .btn-danger:hover { filter: brightness(1.1); }
  .btn-outline {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border);
    color: var(--text);
  }
  .btn-outline:hover { background: rgba(255, 255, 255, 0.1); border-color: #64748b; }
  .btn-sm { padding: 4px 10px; font-size: 12px; }

  /* Main Container */
  .main-content {
    max-width: 1200px;
    width: 100%;
    margin: 0 auto;
    padding: 24px 20px;
    flex: 1;
  }

  /* Architecture Banner */
  .arch-banner {
    background: linear-gradient(135deg, rgba(79, 70, 229, 0.15) 0%, rgba(6, 182, 212, 0.15) 100%);
    border: 1px solid rgba(99, 102, 241, 0.3);
    border-radius: 12px;
    padding: 18px 24px;
    margin-bottom: 24px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 16px;
  }
  .arch-title {
    font-size: 16px;
    font-weight: 700;
    margin-bottom: 4px;
    color: #fff;
  }
  .arch-desc {
    font-size: 13px;
    color: var(--text-muted);
    max-width: 700px;
    line-height: 1.5;
  }
  .package-chips {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .pkg-chip {
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 11.5px;
    font-weight: 600;
    font-family: var(--font-mono);
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(0, 0, 0, 0.3);
  }
  .pkg-livekit { border-color: #a855f7; color: #d8b4fe; }
  .pkg-google { border-color: #3b82f6; color: #93c5fd; }
  .pkg-permission { border-color: #f59e0b; color: #fde68a; }
  .pkg-teorion { border-color: #10b981; color: #a7f3d0; }
  .pkg-activitylog { border-color: #ef4444; color: #fca5a5; }

  /* Switcher Toolbar */
  .switch-toolbar {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 12px 18px;
    margin-bottom: 24px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 12px;
  }
  .switch-group {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .switch-label {
    font-size: 12.5px;
    font-weight: 700;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-right: 4px;
  }
  .role-btn {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 6px 12px;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .role-btn:hover { background: rgba(255, 255, 255, 0.1); }
  .role-btn.active {
    background: var(--primary);
    border-color: var(--primary-light);
    color: white;
    box-shadow: 0 0 0 2px rgba(99, 102, 241, 0.3);
  }

  /* Controls & Filter Bar */
  .filter-bar {
    display: flex;
    gap: 12px;
    margin-bottom: 20px;
    flex-wrap: wrap;
    align-items: center;
  }
  .search-input {
    flex: 1;
    min-width: 220px;
    background: var(--card-bg);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 9px 14px;
    border-radius: 8px;
    font-size: 13.5px;
    outline: none;
  }
  .search-input:focus { border-color: var(--primary-light); }
  .select-filter {
    background: var(--card-bg);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 9px 12px;
    border-radius: 8px;
    font-size: 13px;
    outline: none;
    cursor: pointer;
  }

  /* Meeting Cards Grid */
  .meeting-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(350px, 1fr));
    gap: 18px;
  }
  .meeting-card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    transition: transform 0.15s ease, border-color 0.15s ease;
    box-shadow: var(--shadow);
  }
  .meeting-card:hover {
    border-color: #475569;
    transform: translateY(-2px);
  }
  .card-top {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 12px;
  }
  .m-title {
    font-size: 17px;
    font-weight: 700;
    color: #fff;
    margin-bottom: 4px;
  }
  .m-classroom {
    font-size: 12.5px;
    color: var(--accent);
    font-weight: 600;
  }
  .status-badge {
    padding: 3px 8px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
  }
  .status-published { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }
  .status-draft { background: rgba(245, 158, 11, 0.2); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.3); }

  .m-desc {
    font-size: 13px;
    color: var(--text-muted);
    line-height: 1.5;
    margin-bottom: 16px;
    min-height: 38px;
  }

  .m-meta {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 8px;
    padding: 10px 14px;
    font-size: 12px;
    margin-bottom: 16px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .meta-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .meta-val {
    font-family: var(--font-mono);
    color: #e2e8f0;
  }

  .room-window-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 11.5px;
    padding: 3px 8px;
    border-radius: 6px;
    font-weight: 600;
  }
  .room-open { background: rgba(16, 185, 129, 0.15); color: #10b981; }
  .room-closed { background: rgba(239, 68, 68, 0.15); color: #ef4444; }
  .room-early { background: rgba(245, 158, 11, 0.15); color: #f59e0b; }

  .card-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    padding-top: 14px;
    border-top: 1px solid var(--border);
    flex-wrap: wrap;
  }

  /* Modals */
  .modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.75);
    backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 50;
    padding: 16px;
  }
  .modal-box {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 14px;
    max-width: 600px;
    width: 100%;
    padding: 24px;
    box-shadow: var(--shadow-lg);
    max-height: 90vh;
    overflow-y: auto;
  }
  .modal-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 18px;
  }
  .modal-title {
    font-size: 18px;
    font-weight: 700;
    color: #fff;
  }
  .close-btn {
    background: transparent;
    border: none;
    color: var(--text-muted);
    font-size: 20px;
    cursor: pointer;
    line-height: 1;
  }
  .close-btn:hover { color: #fff; }

  /* Form Elements */
  .form-group {
    margin-bottom: 14px;
  }
  .form-label {
    display: block;
    font-size: 12.5px;
    font-weight: 600;
    margin-bottom: 6px;
    color: var(--text-muted);
  }
  .form-input, .form-textarea, .form-select {
    width: 100%;
    background: #090e1a;
    border: 1px solid var(--border);
    color: var(--text);
    padding: 9px 12px;
    border-radius: 8px;
    font-size: 13.5px;
    outline: none;
  }
  .form-input:focus, .form-textarea:focus, .form-select:focus {
    border-color: var(--primary-light);
  }
  .form-error-alert {
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid var(--danger);
    color: #fca5a5;
    padding: 10px 14px;
    border-radius: 8px;
    font-size: 13px;
    margin-bottom: 14px;
  }

  /* Preset buttons in modal */
  .preset-row {
    display: flex;
    gap: 8px;
    margin-top: 6px;
    margin-bottom: 14px;
    flex-wrap: wrap;
  }
  .preset-btn {
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid var(--border);
    color: #cbd5e1;
    font-size: 11px;
    padding: 4px 8px;
    border-radius: 6px;
    cursor: pointer;
  }
  .preset-btn:hover { background: rgba(255, 255, 255, 0.15); color: #fff; }

  /* LiveKit Room Stage Modal */
  .room-modal {
    max-width: 900px;
  }
  .stage-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
    gap: 12px;
    margin: 18px 0;
  }
  .video-tile {
    background: #0a0f1d;
    border: 2px solid #1e293b;
    border-radius: 10px;
    aspect-ratio: 16/9;
    position: relative;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    padding: 12px;
    box-shadow: inset 0 0 20px rgba(0,0,0,0.5);
  }
  .video-tile.speaking {
    border-color: var(--success);
    box-shadow: 0 0 12px rgba(16, 185, 129, 0.4);
  }
  .avatar-circle {
    width: 54px;
    height: 54px;
    border-radius: 50%;
    background: linear-gradient(135deg, var(--primary) 0%, var(--accent) 100%);
    margin: auto;
    display: grid;
    place-items: center;
    font-size: 22px;
    font-weight: 700;
    color: white;
  }
  .tile-name {
    font-size: 12.5px;
    font-weight: 600;
    background: rgba(0,0,0,0.6);
    padding: 2px 8px;
    border-radius: 4px;
    align-self: flex-start;
  }
  .tile-badge {
    position: absolute;
    top: 10px;
    right: 10px;
    font-size: 10px;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 4px;
  }
  .badge-admin { background: #d97706; color: #fff; }
  .badge-student { background: #059669; color: #fff; }

  .room-controls {
    display: flex;
    justify-content: center;
    gap: 12px;
    margin-top: 18px;
    padding-top: 14px;
    border-top: 1px solid var(--border);
    flex-wrap: wrap;
  }

  .jwt-box {
    background: #090e1a;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 12px;
    font-family: var(--font-mono);
    font-size: 11.5px;
    margin-top: 14px;
    max-height: 120px;
    overflow-y: auto;
    word-break: break-all;
    color: #a5b4fc;
  }

  /* Table */
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 12.5px;
  }
  th, td {
    padding: 9px 12px;
    text-align: left;
    border-bottom: 1px solid var(--border);
  }
  th {
    background: rgba(0,0,0,0.3);
    color: var(--text-muted);
    font-weight: 600;
  }

  /* Empty state */
  .empty-state {
    text-align: center;
    padding: 48px 20px;
    background: var(--card-bg);
    border: 1px dashed var(--border);
    border-radius: 12px;
  }

  /* Toast Notification */
  .toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    background: #1e293b;
    border: 1px solid var(--border);
    color: white;
    padding: 12px 18px;
    border-radius: 8px;
    box-shadow: var(--shadow-lg);
    z-index: 100;
    font-size: 13.5px;
    display: flex;
    align-items: center;
    gap: 10px;
    animation: fadeIn 0.2s ease;
  }
  @keyframes fadeIn {
    from { opacity: 0; transform: translateY(10px); }
    to { opacity: 1; transform: translateY(0); }
  }
</style>
</head>
<body>

<!-- Top Header -->
<header class="top-header">
  <div class="brand-group">
    <div class="brand-logo"><img src="$daravelLogoDataUri" width="30" height="30" alt="Logo"></div>
    <div>
      <div class="brand-title">Virtual Classroom Daravel</div>
      <div class="brand-sub">Sistem Kelas Video WebRTC & Integrasi Kalender Sekolah &middot; Daravel AOT</div>
    </div>
  </div>

  <div class="nav-actions">
    <!-- Current User Pill -->
    <div class="user-switcher" id="currentUserPill">
      <span style="opacity: 0.7;">Masuk sebagai:</span>
      <strong id="currentUserName">Teacher</strong>
      <span id="currentUserRoleBadge" class="user-role-badge role-teacher">TEACHER</span>
    </div>

    <!-- Modals Triggers -->
    <button class="btn btn-outline" onclick="openCalendarModal()">📅 Google Calendar</button>
    <button class="btn btn-outline" onclick="openActivityModal()">📜 Activity Log</button>
    <button class="btn btn-outline btn-sm" onclick="loadAllData()" title="Segarkan Data">🔄 Refresh</button>
  </div>
</header>

<main class="main-content">

  <!-- Architecture Showcase Banner -->
  <div class="arch-banner">
    <div>
      <div class="arch-title">Ekosistem Monorepo First-Party Daravel</div>
      <div class="arch-desc">
        Aplikasi ini memadukan 5 paket first-party untuk skenario kelas online: WebRTC LiveKit, sinkronisasi Google Calendar via queue, Spatie permission RBAC, filter pencarian Teorion, dan Activity Log audit trail.
      </div>
    </div>
    <div class="package-chips">
      <span class="pkg-chip pkg-livekit">daravel_livekit</span>
      <span class="pkg-chip pkg-google">daravel_google</span>
      <span class="pkg-chip pkg-permission">daravel_permission</span>
      <span class="pkg-chip pkg-teorion">daravel_teorion</span>
      <span class="pkg-chip pkg-activitylog">daravel_activitylog</span>
    </div>
  </div>

  <!-- Role Switcher Toolbar -->
  <div class="switch-toolbar">
    <div class="switch-group">
      <span class="switch-label">Ganti Akun Demo:</span>
      <button class="role-btn active" id="btnRoleTeacher" onclick="switchUser('teacher@example.com', 'teacher')">
        👨‍🏫 Guru (Teacher)
      </button>
      <button class="role-btn" id="btnRoleStudent1" onclick="switchUser('student1@example.com', 'student')">
        👩‍🎓 Siswa 1 (Enrolled)
      </button>
      <button class="role-btn" id="btnRoleStudent2" onclick="switchUser('student2@example.com', 'student')">
        👨‍🎓 Siswa 2 (Enrolled)
      </button>
      <button class="role-btn" id="btnRoleOutsider" onclick="switchUser('outsider@example.com', 'outsider')">
        👤 Orang Luar (Uji 403 Forbidden)
      </button>
    </div>

    <div id="teacherActionArea" style="display: block;">
      <button class="btn btn-primary" onclick="openCreateMeetingModal()">
        ➕ Jadwalkan Pelajaran Baru
      </button>
    </div>
  </div>

  <!-- Filter & Search Bar (daravel_teorion) -->
  <div class="filter-bar">
    <input type="text" id="filterSearch" class="search-input" placeholder="🔍 Cari pelajaran (q= via daravel_teorion)..." oninput="debounceSearch()">
    
    <select id="filterStatus" class="select-filter" onchange="applyFilters()">
      <option value="">Semua Status</option>
      <option value="published">Hanya Published</option>
      <option value="draft">Hanya Draft</option>
    </select>

    <select id="filterSort" class="select-filter" onchange="applyFilters()">
      <option value="starts_at">Urutkan: Waktu Mulai (Terdekat)</option>
      <option value="-starts_at">Urutkan: Waktu Mulai (Terlama)</option>
      <option value="name">Urutkan: Nama (A-Z)</option>
    </select>
  </div>

  <!-- Meeting Cards List -->
  <div id="meetingListContainer" class="meeting-grid">
    <div class="empty-state" style="grid-column: 1 / -1;">
      Memuat daftar pelajaran...
    </div>
  </div>

</main>

<!-- MODAL 1: Create / Edit Meeting -->
<div id="createMeetingModal" class="modal-overlay" style="display: none;">
  <div class="modal-box">
    <div class="modal-header">
      <h3 class="modal-title" id="formModalTitle">Jadwalkan Pelajaran Baru</h3>
      <button class="close-btn" onclick="closeCreateMeetingModal()">&times;</button>
    </div>

    <div id="formErrorBox" class="form-error-alert" style="display: none;"></div>

    <form id="meetingForm" onsubmit="handleSaveMeeting(event)">
      <input type="hidden" id="formMeetingId">

      <div class="form-group">
        <label class="form-label">Kelas</label>
        <select id="formClassroomId" class="form-select" required></select>
      </div>

      <div class="form-group">
        <label class="form-label">Nama Pelajaran / Topik</label>
        <input type="text" id="formName" class="form-input" placeholder="Contoh: Aljabar Linear" required>
      </div>

      <div class="form-group">
        <label class="form-label">Deskripsi / Materi</label>
        <textarea id="formDescription" class="form-textarea" rows="2" placeholder="Catatan atau instruksi untuk siswa"></textarea>
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px;">
        <div class="form-group">
          <label class="form-label">Waktu Mulai</label>
          <input type="datetime-local" id="formStartsAt" class="form-input" required>
        </div>
        <div class="form-group">
          <label class="form-label">Waktu Selesai</label>
          <input type="datetime-local" id="formEndsAt" class="form-input" required>
        </div>
      </div>

      <div class="preset-row">
        <span style="font-size: 11px; color: var(--text-muted); align-self: center;">Pilihan Cepat Waktu:</span>
        <button type="button" class="preset-btn" onclick="setPresetTime(5, 45)">⏱️ Buka Room Sekarang (+5m s.d +50m)</button>
        <button type="button" class="preset-btn" onclick="setPresetTime(60, 45)">⏳ 1 Jam Lagi (Belum Buka)</button>
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px;">
        <div class="form-group">
          <label class="form-label">Kapasitas Maksimal (LiveKit Room)</label>
          <input type="number" id="formMaxParticipants" class="form-input" value="40" min="2" max="500">
        </div>
        <div class="form-group">
          <label class="form-label">Status Awal</label>
          <select id="formStatus" class="form-select">
            <option value="published">Published (Siswa & Kalender)</option>
            <option value="draft">Draft (Hanya Guru)</option>
          </select>
        </div>
      </div>

      <div style="display: flex; justify-content: flex-end; gap: 10px; margin-top: 18px;">
        <button type="button" class="btn btn-outline" onclick="closeCreateMeetingModal()">Batal</button>
        <button type="submit" class="btn btn-primary" id="btnSubmitMeeting">Simpan Pelajaran</button>
      </div>
    </form>
  </div>
</div>

<!-- MODAL 2: LiveKit Video Stage (Interactive Simulator) -->
<div id="livekitStageModal" class="modal-overlay" style="display: none;">
  <div class="modal-box room-modal">
    <div class="modal-header">
      <div>
        <h3 class="modal-title" id="stageMeetingTitle">Ruang Kelas Video (LiveKit)</h3>
        <div style="font-size: 12px; color: var(--accent); margin-top: 2px;" id="stageRoomName">Room: -</div>
      </div>
      <button class="close-btn" onclick="closeStageModal()">&times;</button>
    </div>

    <!-- Active Stage Participants -->
    <div class="stage-grid" id="stageParticipantsGrid">
      <!-- Injected via JS -->
    </div>

    <!-- Host / Participant Controls -->
    <div class="room-controls">
      <button class="btn btn-outline" id="btnMicToggle" onclick="toggleMic()">🎤 Mic: Aktif</button>
      <button class="btn btn-outline" id="btnCamToggle" onclick="toggleCam()">📹 Kamera: Aktif</button>
      <button class="btn btn-outline" id="btnRaiseHand" onclick="toggleRaiseHand()">✋ Angkat Tangan</button>
      <button class="btn btn-warning" id="btnMuteAll" style="display: none;" onclick="simulateMuteAll()">🔇 Mute Semua (Guru Admin)</button>
      <button class="btn btn-danger" onclick="closeStageModal()">Keluar Ruang</button>
    </div>

    <!-- LiveKit JWT Token Claims Inspector -->
    <div style="margin-top: 18px;">
      <div style="font-size: 12px; font-weight: 700; color: var(--text-muted); text-transform: uppercase;">
        Detail Kredensial Token LiveKit (daravel_livekit):
      </div>
      <div class="jwt-box" id="jwtTokenDisplay">Memuat token...</div>
    </div>
  </div>
</div>

<!-- MODAL 3: Google Calendar Synced Events -->
<div id="calendarModal" class="modal-overlay" style="display: none;">
  <div class="modal-box" style="max-width: 750px;">
    <div class="modal-header">
      <h3 class="modal-title">📅 Google Calendar Sync Preview (daravel_google)</h3>
      <button class="close-btn" onclick="closeCalendarModal()">&times;</button>
    </div>
    <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 16px;">
      Pelajaran dengan status <strong>published</strong> otomatis dikirim ke antrean (Queue) untuk dimasukkan ke Google Calendar sekolah dengan siswa sebagai <em>attendees</em>.
    </p>

    <div style="overflow-x: auto;">
      <table>
        <thead>
          <tr>
            <th>Event / Topik</th>
            <th>Waktu Pelajaran</th>
            <th>Tamu Siswa (Attendees)</th>
            <th>ID Event Google</th>
          </tr>
        </thead>
        <tbody id="calendarTableBody">
          <tr><td colspan="4" style="text-align: center;">Belum ada event kalender</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<!-- MODAL 4: Activity Log / Audit Trail -->
<div id="activityModal" class="modal-overlay" style="display: none;">
  <div class="modal-box" style="max-width: 750px;">
    <div class="modal-header">
      <h3 class="modal-title">📜 Activity Log Audit Trail (daravel_activitylog)</h3>
      <button class="close-btn" onclick="closeActivityModal()">&times;</button>
    </div>
    <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 16px;">
      Riwayat perubahan jadwal pelajaran secara transparan dan aman tercatat di database tanpa membebani logika controller.
    </p>

    <div style="overflow-x: auto;">
      <table>
        <thead>
          <tr>
            <th>Waktu</th>
            <th>Aksi (Event)</th>
            <th>Keterangan / Subject</th>
            <th>Detail Perubahan</th>
          </tr>
        </thead>
        <tbody id="activityTableBody">
          <tr><td colspan="4" style="text-align: center;">Belum ada catatan aktivitas</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<!-- Client App Logic -->
<script>
  let currentUser = {
    email: 'teacher@example.com',
    name: 'Teacher',
    role: 'teacher',
    token: null
  };

  let appState = {
    users: [],
    classrooms: [{ id: 1, name: 'Mathematics 7A', students_count: 3 }],
    calendarEvents: [],
    activities: [],
    serverNow: new Date()
  };

  let searchTimeout = null;
  let activeMic = true;
  let activeCam = true;
  let handRaised = false;

  async function initApp() {
    // Restore or initialize as teacher
    const savedEmail = localStorage.getItem('vc_user_email') || 'teacher@example.com';
    const savedRole = localStorage.getItem('vc_user_role') || 'teacher';
    await switchUser(savedEmail, savedRole);
  }

  async function loadAllData() {
    try {
      const res = await fetch('/api/demo/state');
      if (res.ok) {
        appState = await res.json();
        appState.serverNow = new Date(appState.server_now);
      }
    } catch (e) {
      console.warn('Demo state fetch warning:', e);
    }
    renderClassroomSelect();
    await fetchMeetings();
  }

  async function switchUser(email, roleKey) {
    try {
      const res = await fetch('/api/auth/demo-switch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email })
      });
      if (!res.ok) throw new Error('Gagal beralih akun demo (HTTP ' + res.status + ')');
      const data = await res.json();
      currentUser = {
        email: data.user.email,
        name: data.user.name,
        role: data.user.role,
        token: data.token
      };

      // Persist in localStorage
      localStorage.setItem('vc_user_email', currentUser.email);
      localStorage.setItem('vc_user_role', currentUser.role);
      localStorage.setItem('vc_token', currentUser.token);

      // Update UI Header
      document.getElementById('currentUserName').innerText = currentUser.name;
      const roleBadge = document.getElementById('currentUserRoleBadge');
      roleBadge.innerText = currentUser.role.toUpperCase();
      roleBadge.className = 'user-role-badge ' + (currentUser.role === 'teacher' ? 'role-teacher' : (currentUser.role === 'student' ? 'role-student' : 'role-outsider'));

      // Update Toolbar buttons active state
      document.querySelectorAll('.role-btn').forEach(btn => btn.classList.remove('active'));
      if (email.includes('teacher')) document.getElementById('btnRoleTeacher').classList.add('active');
      else if (email.includes('student1')) document.getElementById('btnRoleStudent1').classList.add('active');
      else if (email.includes('student2')) document.getElementById('btnRoleStudent2').classList.add('active');
      else document.getElementById('btnRoleOutsider').classList.add('active');

      // Teacher action area visibility
      document.getElementById('teacherActionArea').style.display = (currentUser.role === 'teacher') ? 'block' : 'none';

      showToast('Masuk sebagai: ' + currentUser.name + ' (' + currentUser.role + ')');
      await loadAllData();
    } catch (e) {
      showToast('Login gagal: ' + e.message, true);
    }
  }

  function renderClassroomSelect() {
    const sel = document.getElementById('formClassroomId');
    sel.innerHTML = '';
    const classrooms = (appState.classrooms && appState.classrooms.length > 0)
      ? appState.classrooms
      : [{ id: 1, name: 'Mathematics 7A', students_count: 3 }];

    classrooms.forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.id;
      opt.innerText = c.name + ' (' + (c.students_count || 3) + ' Siswa)';
      sel.appendChild(opt);
    });
  }

  function debounceSearch() {
    clearTimeout(searchTimeout);
    searchTimeout = setTimeout(fetchMeetings, 250);
  }

  function applyFilters() {
    fetchMeetings();
  }

  async function fetchMeetings() {
    if (!currentUser.token) {
      return;
    }

    const q = document.getElementById('filterSearch').value.trim();
    const status = document.getElementById('filterStatus').value;
    const sort = document.getElementById('filterSort').value;

    let url = '/api/meetings?';
    const params = new URLSearchParams();
    if (q) params.set('q', q);
    if (status) params.set('status', status);
    if (sort) params.set('sort', sort);
    url += params.toString();

    try {
      const res = await fetch(url, {
        headers: {
          'Authorization': 'Bearer ' + currentUser.token,
          'Accept': 'application/json'
        }
      });

      const container = document.getElementById('meetingListContainer');
      if (!res.ok) {
        if (res.status === 403) {
          container.innerHTML = '<div class="empty-state" style="grid-column: 1 / -1; border-color: var(--danger);"><h4 style="color: var(--danger); margin-bottom: 6px;">⛔ 403 Akses Ditolak</h4><p style="font-size: 13px; color: var(--text-muted);">Akun ' + escapeHtml(currentUser.name) + ' tidak memiliki hak akses pada kelas ini.</p></div>';
        } else {
          container.innerHTML = '<div class="empty-state" style="grid-column: 1 / -1;">Error memuat data: HTTP ' + res.status + '</div>';
        }
        return;
      }

      const json = await res.json();
      const list = json.data || [];
      renderMeetings(list);
    } catch (e) {
      document.getElementById('meetingListContainer').innerHTML = '<div class="empty-state" style="grid-column: 1 / -1;">Gagal mengambil data meeting: ' + escapeHtml(e.message) + '</div>';
    }
  }

  function renderMeetings(meetings) {
    const container = document.getElementById('meetingListContainer');
    if (!meetings || meetings.length === 0) {
      container.innerHTML = `
        <div class="empty-state" style="grid-column: 1 / -1;">
          <h4 style="margin-bottom: 6px;">Belum ada jadwal pelajaran</h4>
          <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 14px;">
            Jadwal pelajaran yang dipublikasikan akan muncul di sini dan otomatis masuk ke Google Calendar.
          </p>
          \${currentUser.role === 'teacher' ? '<button class="btn btn-primary" onclick="openCreateMeetingModal()">➕ Jadwalkan Sekarang</button>' : ''}
        </div>
      `;
      return;
    }

    container.innerHTML = '';
    const now = new Date();

    meetings.forEach(m => {
      const starts = new Date(m.starts_at);
      const ends = new Date(m.ends_at);
      const earlyJoin = new Date(starts.getTime() - 15 * 60 * 1000);

      let roomStatusHtml = '';
      let canJoin = false;

      if (now >= earlyJoin && now < ends) {
        roomStatusHtml = '<span class="room-window-badge room-open">🟢 Room Buka (Bisa Masuk)</span>';
        canJoin = true;
      } else if (now < earlyJoin) {
        const diffMins = Math.round((starts - now) / 60000);
        roomStatusHtml = '<span class="room-window-badge room-early">⏳ Buka 15 Menit Sebelum Mulai (' + diffMins + 'm lagi)</span>';
      } else {
        roomStatusHtml = '<span class="room-window-badge room-closed">🔴 Pelajaran Selesai / Ditutup</span>';
      }

      const isTeacher = (currentUser.role === 'teacher');
      const isPublished = (m.status === 'published');
      const meetingId = m.id || m.uuid;
      const classroomName = (appState.classrooms && appState.classrooms.length > 0)
        ? appState.classrooms[0].name
        : 'Mathematics 7A';

      const card = document.createElement('div');
      card.className = 'meeting-card';
      card.innerHTML = `
        <div>
          <div class="card-top">
            <div>
              <div class="m-title">\${escapeHtml(m.name)}</div>
              <div class="m-classroom">\${escapeHtml(classroomName)}</div>
            </div>
            <span class="status-badge \${isPublished ? 'status-published' : 'status-draft'}">\${m.status.toUpperCase()}</span>
          </div>

          <div class="m-desc">\${escapeHtml(m.description || 'Tidak ada catatan materi tambahan.')}</div>

          <div class="m-meta">
            <div class="meta-row">
              <span style="color: var(--text-muted);">Mulai:</span>
              <span class="meta-val">\${formatDateTime(starts)}</span>
            </div>
            <div class="meta-row">
              <span style="color: var(--text-muted);">Selesai:</span>
              <span class="meta-val">\${formatDateTime(ends)}</span>
            </div>
            <div class="meta-row">
              <span style="color: var(--text-muted);">Status Room:</span>
              <span>\${roomStatusHtml}</span>
            </div>
            <div class="meta-row">
              <span style="color: var(--text-muted);">Kapasitas:</span>
              <span class="meta-val">\${m.max_participants || 40} Peserta</span>
            </div>
          </div>
        </div>

        <div class="card-footer">
          <div>
            <button class="btn btn-primary" onclick="handleJoinMeeting('\${meetingId}', '\${escapeHtml(m.name)}')">
              🚀 Masuk LiveKit Room
            </button>
          </div>

          \${isTeacher ? `
            <div style="display: flex; gap: 6px;">
              <button class="btn btn-outline btn-sm" onclick="togglePublishStatus('\${meetingId}', '\${m.status}')" title="Publikasikan / Draft">
                \${isPublished ? '🔒 Jadikan Draft' : '📢 Publikasikan'}
              </button>
              <button class="btn btn-outline btn-sm" style="color: var(--danger); border-color: rgba(239,68,68,0.3);" onclick="handleDeleteMeeting('\${meetingId}')" title="Hapus">
                🗑
              </button>
            </div>
          ` : ''}
        </div>
      `;
      container.appendChild(card);
    });
  }

  // Meeting CRUD
  function setPresetTime(startMinutesFromNow, durationMinutes) {
    const now = new Date();
    const start = new Date(now.getTime() + startMinutesFromNow * 60 * 1000);
    const end = new Date(start.getTime() + durationMinutes * 60 * 1000);

    document.getElementById('formStartsAt').value = toLocalISOString(start);
    document.getElementById('formEndsAt').value = toLocalISOString(end);
  }

  function openCreateMeetingModal() {
    renderClassroomSelect();
    document.getElementById('formErrorBox').style.display = 'none';
    document.getElementById('formModalTitle').innerText = 'Jadwalkan Pelajaran Baru';
    document.getElementById('formMeetingId').value = '';
    document.getElementById('formName').value = '';
    document.getElementById('formDescription').value = '';
    
    // Default preset: start 5m from now, duration 45m (Room opens immediately!)
    setPresetTime(5, 45);
    document.getElementById('formMaxParticipants').value = 40;
    document.getElementById('formStatus').value = 'published';

    document.getElementById('createMeetingModal').style.display = 'flex';
  }

  function closeCreateMeetingModal() {
    document.getElementById('createMeetingModal').style.display = 'none';
  }

  async function handleSaveMeeting(e) {
    e.preventDefault();
    const errBox = document.getElementById('formErrorBox');
    errBox.style.display = 'none';

    const btn = document.getElementById('btnSubmitMeeting');
    btn.disabled = true;
    btn.innerText = 'Menyimpan...';

    try {
      if (!currentUser.token) {
        await switchUser('teacher@example.com', 'teacher');
      }

      let classroomId = document.getElementById('formClassroomId').value;
      if (!classroomId) classroomId = '1';

      const name = document.getElementById('formName').value.trim();
      if (!name) throw new Error('Nama pelajaran wajib diisi.');

      const startVal = document.getElementById('formStartsAt').value;
      const endVal = document.getElementById('formEndsAt').value;

      let start = startVal ? new Date(startVal) : new Date(Date.now() + 5 * 60000);
      if (isNaN(start.getTime())) start = new Date(Date.now() + 5 * 60000);

      let end = endVal ? new Date(endVal) : new Date(start.getTime() + 45 * 60000);
      if (isNaN(end.getTime()) || end <= start) {
        end = new Date(start.getTime() + 45 * 60000);
      }

      const body = {
        name: name,
        description: document.getElementById('formDescription').value.trim(),
        starts_at: start.toISOString(),
        ends_at: end.toISOString(),
        max_participants: parseInt(document.getElementById('formMaxParticipants').value) || 40,
        status: document.getElementById('formStatus').value
      };

      const res = await fetch('/api/classrooms/' + classroomId + '/meetings', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + currentUser.token,
          'Accept': 'application/json'
        },
        body: JSON.stringify(body)
      });

      if (!res.ok) {
        let msg = 'HTTP ' + res.status;
        try {
          const err = await res.json();
          msg = err.message || JSON.stringify(err);
        } catch (_) {}
        throw new Error(msg);
      }

      showToast('Pelajaran baru berhasil dibuat & disinkronkan ke kalender!');
      closeCreateMeetingModal();
      await loadAllData();
    } catch (err) {
      errBox.innerText = 'Gagal menyimpan pelajaran: ' + err.message;
      errBox.style.display = 'block';
      showToast('Gagal: ' + err.message, true);
    } finally {
      btn.disabled = false;
      btn.innerText = 'Simpan Pelajaran';
    }
  }

  async function togglePublishStatus(id, currentStatus) {
    const nextStatus = (currentStatus === 'published') ? 'draft' : 'published';
    try {
      const res = await fetch('/api/meetings/' + id, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + currentUser.token,
          'Accept': 'application/json'
        },
        body: JSON.stringify({ status: nextStatus })
      });

      if (!res.ok) throw new Error('HTTP ' + res.status);
      showToast('Status berhasil diubah ke: ' + nextStatus.toUpperCase() + ' (Google Calendar otomatis menyesuaikan)');
      await loadAllData();
    } catch (e) {
      showToast('Gagal mengubah status: ' + e.message, true);
    }
  }

  async function handleDeleteMeeting(id) {
    if (!confirm('Yakin ingin menghapus pelajaran ini? Event Google Calendar terkait juga akan dihapus.')) return;
    try {
      const res = await fetch('/api/meetings/' + id, {
        method: 'DELETE',
        headers: {
          'Authorization': 'Bearer ' + currentUser.token,
          'Accept': 'application/json'
        }
      });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      showToast('Pelajaran dan event kalender berhasil dihapus.');
      await loadAllData();
    } catch (e) {
      showToast('Gagal: ' + e.message, true);
    }
  }

  // Join LiveKit Room
  async function handleJoinMeeting(id, meetingName) {
    try {
      const res = await fetch('/api/meetings/' + id + '/join', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + currentUser.token,
          'Accept': 'application/json'
        }
      });

      if (res.status === 409) {
        const data = await res.json().catch(() => ({}));
        alert('⚠️ 409 ROOM DITUTUP / BELUM BUKA:\n\n' + (data.message || 'The room opens 15 minutes before the meeting starts and closes when it ends.'));
        return;
      }

      if (res.status === 403) {
        alert('⛔ 403 FORBIDDEN:\n\nAkun Anda (' + currentUser.name + ') bukan siswa di kelas ini dan bukan guru pengampu. Akses room ditolak.');
        return;
      }

      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.message || ('HTTP ' + res.status));
      }

      const pass = await res.json();
      openStageModal(meetingName, pass);
    } catch (e) {
      showToast('Gagal masuk room: ' + e.message, true);
    }
  }

  function openStageModal(meetingName, pass) {
    document.getElementById('stageMeetingTitle').innerText = meetingName;
    document.getElementById('stageRoomName').innerText = 'LiveKit Room: ' + pass.room + ' (' + pass.url + ')';

    // Parse and show Token JWT
    document.getElementById('jwtTokenDisplay').innerHTML = `
      <div><strong>LiveKit WebRTC Server:</strong> \${pass.url}</div>
      <div><strong>Admin Grant:</strong> \${pass.admin ? '<span style="color: #fbbf24;">TRUE (Host/Guru)</span>' : '<span style="color: #34d399;">FALSE (Siswa)</span>'}</div>
      <div><strong>Token Expires At:</strong> \${pass.expires_at}</div>
      <div style="margin-top: 6px; word-break: break-all;"><strong>Signed JWT Token:</strong><br>\${pass.token}</div>
    `;

    // Teacher Host Controls
    document.getElementById('btnMuteAll').style.display = pass.admin ? 'inline-flex' : 'none';

    // Render Participant Tiles
    const grid = document.getElementById('stageParticipantsGrid');
    grid.innerHTML = `
      <div class="video-tile speaking">
        <span class="tile-badge \${pass.admin ? 'badge-admin' : 'badge-student'}">\${pass.admin ? 'HOST / ADMIN' : 'PARTICIPANT'}</span>
        <div class="avatar-circle">\${currentUser.name.charAt(0)}</div>
        <div class="tile-name">\${currentUser.name} (Anda) \${pass.admin ? '👑' : ''}</div>
      </div>
      <div class="video-tile">
        <span class="tile-badge badge-student">STUDENT</span>
        <div class="avatar-circle" style="background: #0d9488;">S1</div>
        <div class="tile-name">Student 1 🎤</div>
      </div>
      <div class="video-tile">
        <span class="tile-badge badge-student">STUDENT</span>
        <div class="avatar-circle" style="background: #e11d48;">S2</div>
        <div class="tile-name">Student 2 🎤</div>
      </div>
    `;

    document.getElementById('livekitStageModal').style.display = 'flex';
  }

  function closeStageModal() {
    document.getElementById('livekitStageModal').style.display = 'none';
  }

  function toggleMic() {
    activeMic = !activeMic;
    const btn = document.getElementById('btnMicToggle');
    btn.innerText = activeMic ? '🎤 Mic: Aktif' : '🔇 Mic: Muted';
    btn.className = activeMic ? 'btn btn-outline' : 'btn btn-warning';
  }

  function toggleCam() {
    activeCam = !activeCam;
    const btn = document.getElementById('btnCamToggle');
    btn.innerText = activeCam ? '📹 Kamera: Aktif' : '🚫 Kamera: Nonaktif';
    btn.className = activeCam ? 'btn btn-outline' : 'btn btn-warning';
  }

  function toggleRaiseHand() {
    handRaised = !handRaised;
    const btn = document.getElementById('btnRaiseHand');
    btn.innerText = handRaised ? '✋ Tangan Diangkat' : '✋ Angkat Tangan';
    btn.className = handRaised ? 'btn btn-warning' : 'btn btn-outline';
    showToast(handRaised ? 'Anda mengangkat tangan di kelas!' : 'Menurunkan tangan.');
  }

  function simulateMuteAll() {
    showToast('Admin Room Command: Mematikan mic semua siswa di room!');
  }

  // Google Calendar Modal
  function openCalendarModal() {
    const tbody = document.getElementById('calendarTableBody');
    tbody.innerHTML = '';
    const events = appState.calendar_events || [];

    if (events.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" style="text-align: center; color: var(--text-muted);">Belum ada jadwal berstatus published</td></tr>';
    } else {
      events.forEach(ev => {
        const tr = document.createElement('tr');
        tr.innerHTML = `
          <td><strong>\${escapeHtml(ev.summary)}</strong></td>
          <td>\${formatDateTime(new Date(ev.starts_at))}</td>
          <td>\${(ev.attendees || []).map(a => '<span style="background: rgba(255,255,255,0.08); padding: 2px 6px; border-radius: 4px; font-size: 11px; margin-right: 4px;">' + escapeHtml(a) + '</span>').join('')}</td>
          <td><code style="color: var(--accent); font-size: 11px;">\${ev.event_id}</code></td>
        `;
        tbody.appendChild(tr);
      });
    }

    document.getElementById('calendarModal').style.display = 'flex';
  }

  function closeCalendarModal() {
    document.getElementById('calendarModal').style.display = 'none';
  }

  // Activity Log Modal
  function openActivityModal() {
    const tbody = document.getElementById('activityTableBody');
    tbody.innerHTML = '';
    const logs = appState.recent_activities || [];

    if (logs.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" style="text-align: center; color: var(--text-muted);">Belum ada riwayat aktivitas</td></tr>';
    } else {
      logs.forEach(act => {
        const tr = document.createElement('tr');
        const eventColor = act.event === 'created' ? 'var(--success)' : (act.event === 'deleted' ? 'var(--danger)' : 'var(--warning)');
        tr.innerHTML = `
          <td style="color: var(--text-muted); font-size: 11px;">\${act.created_at ? formatDateTime(new Date(act.created_at)) : '-'}</td>
          <td><span style="color: \${eventColor}; font-weight: 700; text-transform: uppercase;">\${act.event || 'action'}</span></td>
          <td><strong>\${escapeHtml(act.description || 'Pelajaran')}</strong></td>
          <td><pre style="font-size: 10.5px; color: #a5b4fc; background: rgba(0,0,0,0.3); padding: 4px; border-radius: 4px; max-width: 250px; overflow-x: auto;">\${JSON.stringify(act.properties || {})}</pre></td>
        `;
        tbody.appendChild(tr);
      });
    }

    document.getElementById('activityModal').style.display = 'flex';
  }

  function closeActivityModal() {
    document.getElementById('activityModal').style.display = 'none';
  }

  // Helper formatting
  function formatDateTime(d) {
    return d.toLocaleString('id-ID', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }

  function toLocalISOString(date) {
    const pad = n => (n < 10 ? '0' : '') + n;
    return date.getFullYear() +
      '-' + pad(date.getMonth() + 1) +
      '-' + pad(date.getDate()) +
      'T' + pad(date.getHours()) +
      ':' + pad(date.getMinutes());
  }

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/[&<>'"]/g, tag => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      "'": '&#39;',
      '"': '&quot;'
    }[tag] || tag));
  }

  function showToast(msg, isError) {
    const toast = document.createElement('div');
    toast.className = 'toast';
    if (isError) toast.style.borderColor = 'var(--danger)';
    toast.innerHTML = (isError ? '⚠️ ' : '✅ ') + escapeHtml(msg);
    document.body.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      setTimeout(() => toast.remove(), 200);
    }, 3200);
  }

  // Direct immediate execution (guaranteed across all browsers)
  initApp();
</script>

</body>
</html>
''';
}
