import 'dart:convert';

import 'package:daravel/daravel.dart'
    show App, daravelFaviconDataUri, daravelLogoDataUri, trans;

import '../../lang/ui_lines.dart';

/// Renders the CAT Exam Interactive Web Interface.
String catExamPage({
  required String appName,
  required String environment,
  required String dartVersion,
  required String frameworkVersion,
  required String requestId,
}) {
  final name = escape(appName);
  final locale = App.locale;
  String l(String key) => escape(trans('ui.$key'));
  final script = jsonEncode({
    for (final key in uiScriptKeys) key: trans('ui.$key'),
  });

  return '''
<!doctype html>
<html lang="${escape(locale)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name - Computer Assisted Test (CAT)</title>
<link rel="icon" type="image/png" href="$daravelFaviconDataUri">
<style>
  .lang-switch { display: flex; gap: 4px; margin-left: auto; margin-right: 12px; }
  .lang-switch a { padding: 2px 8px; border-radius: 6px; font-size: 12px; font-weight: 700;
    color: inherit; text-decoration: none; border: 1px solid rgba(255,255,255,0.35); opacity: 0.75; }
  .lang-switch a.active { opacity: 1; background: rgba(255,255,255,0.18); }
  :root {
    --primary: #0f4c81;
    --primary-dark: #092c4c;
    --primary-light: #2b6cb0;
    --accent: #d97706;
    --success: #16a34a;
    --warning: #eab308;
    --danger: #dc2626;
    --bg: #f8fafc;
    --card-bg: #ffffff;
    --border: #e2e8f0;
    --text: #1e293b;
    --text-muted: #64748b;
    --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
    --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1);
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

  /* Header Bar */
  .top-header {
    background: linear-gradient(135deg, var(--primary-dark) 0%, var(--primary) 100%);
    color: white;
    padding: 12px 24px;
    box-shadow: var(--shadow);
    display: flex;
    justify-content: space-between;
    align-items: center;
    position: sticky;
    top: 0;
    z-index: 50;
  }
  .brand-group {
    display: flex;
    align-items: center;
    gap: 14px;
  }
  .brand-badge {
    background: white;
    padding: 4px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .brand-title {
    font-size: 18px;
    font-weight: 700;
    letter-spacing: -0.3px;
  }
  .brand-sub {
    font-size: 12px;
    opacity: 0.85;
    font-weight: 400;
  }

  .timer-box {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .timer-display {
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 8px;
    padding: 6px 14px;
    font-family: var(--font-mono);
    font-size: 20px;
    font-weight: 700;
    letter-spacing: 1px;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .timer-icon {
    font-size: 16px;
  }
  .sync-indicator {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    background: rgba(22, 163, 74, 0.2);
    border: 1px solid rgba(34, 197, 94, 0.4);
    padding: 4px 10px;
    border-radius: 20px;
    color: #4ade80;
  }
  .pulse-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #4ade80;
    box-shadow: 0 0 0 2px rgba(74, 222, 128, 0.4);
    animation: pulse 1.5s infinite;
  }
  @keyframes pulse {
    0% { transform: scale(0.95); opacity: 0.8; }
    50% { transform: scale(1.2); opacity: 1; }
    100% { transform: scale(0.95); opacity: 0.8; }
  }

  /* Candidate Bar */
  .candidate-bar {
    background: white;
    border-bottom: 1px solid var(--border);
    padding: 10px 24px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 13.5px;
  }
  .cand-info {
    display: flex;
    align-items: center;
    gap: 20px;
  }
  .cand-badge {
    background: #eff6ff;
    color: var(--primary);
    border: 1px solid #bfdbfe;
    padding: 3px 8px;
    border-radius: 4px;
    font-weight: 600;
  }

  /* Layout Containers */
  .main-content {
    flex: 1;
    max-width: 1400px;
    width: 100%;
    margin: 0 auto;
    padding: 20px;
  }
  .exam-grid {
    display: grid;
    grid-template-columns: 1fr 340px;
    gap: 20px;
  }

  /* Question Panel */
  .card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    box-shadow: var(--shadow);
    padding: 24px;
  }
  .q-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding-bottom: 16px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 20px;
  }
  .category-pill {
    background: #e0f2fe;
    color: #0369a1;
    font-weight: 700;
    font-size: 13px;
    padding: 4px 12px;
    border-radius: 999px;
    border: 1px solid #bae6fd;
  }
  .q-title {
    font-size: 17px;
    font-weight: 700;
    color: var(--primary-dark);
  }
  .q-body {
    font-size: 16px;
    line-height: 1.6;
    margin-bottom: 24px;
    white-space: pre-line;
  }

  /* Options list */
  .options-group {
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-bottom: 28px;
  }
  .option-item {
    display: flex;
    align-items: flex-start;
    gap: 14px;
    padding: 14px 18px;
    border: 1.5px solid var(--border);
    border-radius: 10px;
    background: white;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .option-item:hover {
    border-color: var(--primary-light);
    background: #f8fafc;
  }
  .option-item.selected {
    border-color: var(--primary);
    background: #eff6ff;
    box-shadow: 0 0 0 2px rgba(15, 76, 129, 0.15);
  }
  .opt-letter {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: #f1f5f9;
    color: var(--text);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    font-size: 14px;
    flex-shrink: 0;
    border: 1px solid var(--border);
  }
  .option-item.selected .opt-letter {
    background: var(--primary);
    color: white;
    border-color: var(--primary);
  }
  .opt-text {
    flex: 1;
    font-size: 15px;
    line-height: 1.5;
    padding-top: 4px;
  }

  /* Question Action Buttons */
  .q-actions {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding-top: 18px;
    border-top: 1px solid var(--border);
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 20px;
    border-radius: 8px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    transition: all 0.15s ease;
  }
  .btn-outline {
    background: white;
    border: 1px solid var(--border);
    color: var(--text);
  }
  .btn-outline:hover {
    background: #f1f5f9;
    border-color: #cbd5e1;
  }
  .btn-primary {
    background: var(--primary);
    color: white;
  }
  .btn-primary:hover {
    background: var(--primary-dark);
  }
  .btn-warning {
    background: #fef3c7;
    border: 1px solid #fde68a;
    color: #b45309;
  }
  .btn-warning.active {
    background: var(--accent);
    color: white;
    border-color: var(--accent);
  }
  .btn-danger {
    background: var(--danger);
    color: white;
  }
  .btn-danger:hover {
    background: #b91c1c;
  }
  .btn-success {
    background: var(--success);
    color: white;
  }
  .btn-success:hover {
    background: #15803d;
  }

  /* Palette Sidebar */
  .sidebar-title {
    font-size: 15px;
    font-weight: 700;
    margin-bottom: 14px;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .palette-grid {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 8px;
    margin-bottom: 18px;
  }
  .palette-btn {
    aspect-ratio: 1;
    border-radius: 8px;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    font-size: 13px;
    border: 1.5px solid var(--border);
    background: #f8fafc;
    color: var(--text);
    cursor: pointer;
    transition: all 0.1s ease;
    position: relative;
  }
  .palette-btn:hover {
    border-color: var(--primary-light);
  }
  .palette-btn.active {
    outline: 2px solid var(--primary);
    outline-offset: 2px;
  }
  .palette-btn.answered {
    background: #dcfce7;
    border-color: #86efac;
    color: #166534;
  }
  .palette-btn.doubtful {
    background: #fef08a;
    border-color: #facc15;
    color: #854d0e;
  }
  .palette-choice {
    font-size: 10px;
    font-weight: 800;
    opacity: 0.8;
  }

  .legend-box {
    background: #f8fafc;
    border-radius: 8px;
    padding: 12px;
    margin-bottom: 18px;
    font-size: 12px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .legend-item {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .legend-color {
    width: 14px;
    height: 14px;
    border-radius: 4px;
    border: 1px solid rgba(0, 0, 0, 0.1);
  }

  /* Modals & Screens */
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(15, 23, 42, 0.65);
    backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
    padding: 20px;
  }
  .modal {
    background: white;
    border-radius: 16px;
    max-width: 540px;
    width: 100%;
    padding: 30px;
    box-shadow: var(--shadow-lg);
  }
  .modal-title {
    font-size: 20px;
    font-weight: 700;
    margin-bottom: 10px;
    color: var(--primary-dark);
  }
  .modal-desc {
    color: var(--text-muted);
    font-size: 14px;
    line-height: 1.5;
    margin-bottom: 20px;
  }
  .form-group {
    margin-bottom: 16px;
  }
  .form-label {
    display: block;
    font-size: 13px;
    font-weight: 600;
    margin-bottom: 6px;
  }
  .form-input {
    width: 100%;
    padding: 10px 14px;
    border: 1.5px solid var(--border);
    border-radius: 8px;
    font-size: 15px;
    font-family: inherit;
  }
  .form-input:focus {
    outline: none;
    border-color: var(--primary);
    box-shadow: 0 0 0 3px rgba(15, 76, 129, 0.15);
  }
  .demo-picks {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 14px;
    padding-top: 14px;
    border-top: 1px solid var(--border);
  }
  .pick-btn {
    text-align: left;
    background: #f8fafc;
    border: 1px solid var(--border);
    padding: 8px 12px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 12.5px;
  }
  .pick-btn:hover {
    background: #eff6ff;
    border-color: #93c5fd;
  }

  /* Result Certificate Card */
  .cert-card {
    background: white;
    border-radius: 16px;
    border: 2px solid #cbd5e1;
    padding: 32px;
    max-width: 800px;
    margin: 0 auto;
    box-shadow: var(--shadow-lg);
    position: relative;
    overflow: hidden;
  }
  .cert-header {
    text-align: center;
    border-bottom: 2px solid #e2e8f0;
    padding-bottom: 20px;
    margin-bottom: 24px;
  }
  .cert-seal {
    width: 60px;
    height: 60px;
    margin: 0 auto 12px;
    background: #f1f5f9;
    border-radius: 50%;
    display: grid;
    place-items: center;
    border: 2px solid var(--primary);
  }
  .cert-scores {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 16px;
    margin: 24px 0;
  }
  .score-card {
    background: #f8fafc;
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px;
    text-align: center;
  }
  .score-val {
    font-size: 32px;
    font-weight: 800;
    font-family: var(--font-mono);
    color: var(--primary);
  }
  .score-target {
    font-size: 12px;
    color: var(--text-muted);
    margin-top: 4px;
  }
  .total-banner {
    background: linear-gradient(135deg, var(--primary-dark) 0%, var(--primary) 100%);
    color: white;
    border-radius: 12px;
    padding: 20px;
    text-align: center;
    margin: 20px 0;
  }
  .total-score-num {
    font-size: 48px;
    font-weight: 900;
    font-family: var(--font-mono);
  }
  .pass-badge {
    display: inline-block;
    padding: 6px 16px;
    border-radius: 999px;
    font-weight: 700;
    font-size: 14px;
    margin-top: 8px;
  }
  .pass-badge.passed {
    background: #dcfce7;
    color: #15803d;
  }
  .pass-badge.failed {
    background: #fee2e2;
    color: #b91c1c;
  }

  /* Leaderboard Table */
  .table-box {
    overflow-x: auto;
    margin-top: 20px;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13.5px;
  }
  th, td {
    padding: 10px 14px;
    text-align: left;
    border-bottom: 1px solid var(--border);
  }
  th {
    background: #f8fafc;
    font-weight: 700;
    color: var(--text-muted);
  }

  /* Utility */
  .hidden { display: none !important; }
  .text-danger { color: var(--danger); }
  .text-success { color: var(--success); }
</style>
</head>
<body>

<!-- Header -->
<header class="top-header">
  <div class="brand-group">
    <div class="brand-badge"><img src="$daravelLogoDataUri" width="32" height="32" alt="Logo"></div>
    <div>
      <div class="brand-title">${l('brand_title')}</div>
      <div class="brand-sub">${l('brand_sub')}</div>
    </div>
  </div>

  <nav class="lang-switch" aria-label="Language">
    <a href="?lang=en" class="${locale == 'id' ? '' : 'active'}">EN</a>
    <a href="?lang=id" class="${locale == 'id' ? 'active' : ''}">ID</a>
  </nav>

  <div class="timer-box" id="headerTimerGroup" style="display: none;">
    <div class="sync-indicator">
      <span class="pulse-dot"></span>
      <span id="syncStatus">${l('synced')}</span>
    </div>
    <div class="timer-display">
      <span class="timer-icon">⏱</span>
      <span id="timerText">00:30:00</span>
    </div>
  </div>
</header>

<!-- Candidate Info Bar (Shown during exam) -->
<div class="candidate-bar" id="candidateBar" style="display: none;">
  <div class="cand-info">
    <div><strong>${l('name_label')}</strong> <span id="candNameDisplay">-</span></div>
    <div><strong>NIK:</strong> <span id="candNikDisplay">-</span></div>
    <div><strong>${l('exam_no_label')}</strong> <span id="candNoDisplay" class="cand-badge">-</span></div>
  </div>
  <div>
    <button class="btn btn-outline" style="padding: 4px 10px; font-size: 12px;" onclick="viewLeaderboardModal()">${l('live_board')}</button>
  </div>
</div>

<!-- Main Area -->
<main class="main-content">

  <!-- View 1: Candidate Login Modal -->
  <div id="loginSection" class="overlay">
    <div class="modal">
      <div style="text-align: center; margin-bottom: 20px;">
        <img src="$daravelLogoDataUri" width="48" height="48" alt="Logo" style="margin-bottom: 8px;">
        <h2 class="modal-title">${l('login_title')}</h2>
        <p class="modal-desc">${l('login_desc')}</p>
      </div>

      <div id="loginError" class="form-group text-danger" style="display: none; font-size: 13px; background: #fee2e2; padding: 10px; border-radius: 8px;"></div>

      <div class="form-group">
        <label class="form-label">${l('nik_label')}</label>
        <input type="text" id="loginNik" class="form-input" placeholder="${l('nik_placeholder')}" maxlength="16">
      </div>

      <div class="form-group">
        <label class="form-label">${l('exam_no_field')}</label>
        <input type="text" id="loginExamNo" class="form-input" placeholder="${l('exam_no_placeholder')}">
      </div>

      <button id="btnLogin" class="btn btn-primary" style="width: 100%; justify-content: center; padding: 12px;" onclick="handleCandidateLogin()">
        ${l('start')}
      </button>

      <div class="demo-picks">
        <div style="font-size: 11.5px; font-weight: 700; color: var(--text-muted); text-transform: uppercase;">${l('quick_fill')}</div>
        <button class="pick-btn" onclick="fillCandidate('3201011203950001', 'TKA-2026-001')">
          👤 <strong>Budi Santoso</strong> &middot; NIK: 3201011203950001 (${l('demo_new')})
        </button>
        <button class="pick-btn" onclick="fillCandidate('3201015508960002', 'TKA-2026-002')">
          👤 <strong>Siti Rahmawati</strong> &middot; NIK: 3201015508960002 (${l('demo_second')})
        </button>
        <button class="pick-btn" onclick="fillCandidate('3201012211940003', 'TKA-2026-003')">
          👤 <strong>Ahmad Fauzi</strong> &middot; NIK: 3201012211940003 (${l('demo_conflict')})
        </button>
      </div>
    </div>
  </div>

  <!-- View 2: Device Conflict Modal (409 Anti-Joki) -->
  <div id="conflictModal" class="overlay" style="display: none;">
    <div class="modal">
      <div style="text-align: center; color: var(--danger); margin-bottom: 12px; font-size: 40px;">⚠️</div>
      <h2 class="modal-title" style="text-align: center; color: var(--danger);">${l('conflict_title')}</h2>
      <p id="conflictMessage" class="modal-desc" style="background: #fef2f2; border: 1px solid #fecaca; padding: 12px; border-radius: 8px;"></p>
      <p class="modal-desc">${l('conflict_desc')}</p>
      
      <div style="display: flex; gap: 10px; justify-content: flex-end;">
        <button class="btn btn-outline" onclick="closeConflictModal()">${l('back')}</button>
        <button class="btn btn-warning" onclick="simulateProctorReset()">${l('proctor_reset')}</button>
      </div>
    </div>
  </div>

  <!-- View 3: Active Exam Screen -->
  <div id="examSection" style="display: none;">
    <div class="exam-grid">
      <!-- Left: Question & Answers -->
      <div class="card">
        <div class="q-header">
          <div>
            <span id="currentCategoryPill" class="category-pill">TWK</span>
            <span id="qNumberDisplay" style="margin-left: 10px; font-weight: 700; font-size: 15px;">${l('question_first')}</span>
          </div>
          <div id="saveMicroIndicator" style="font-size: 12px; color: var(--text-muted);">
            Tersimpan
          </div>
        </div>

        <div id="qTextDisplay" class="q-body">${l('loading_question')}</div>

        <div id="optionsContainer" class="options-group">
          <!-- Options rendered via JS -->
        </div>

        <div class="q-actions">
          <button id="btnPrev" class="btn btn-outline" onclick="navigateQuestion(-1)">${l('prev')}</button>
          <button id="btnDoubtful" class="btn btn-warning" onclick="toggleDoubtful()">${l('doubtful')}</button>
          <button id="btnNext" class="btn btn-primary" onclick="navigateQuestion(1)">${l('next')}</button>
        </div>
      </div>

      <!-- Right: Palette Grid -->
      <div class="card">
        <div class="sidebar-title">
          <span>${l('question_list')}</span>
          <span id="progressSummary" style="font-size: 12px; color: var(--text-muted); font-weight: normal;">0 / 15 ${l('answered_suffix')}</span>
        </div>

        <div id="paletteGrid" class="palette-grid">
          <!-- 1..15 buttons generated by JS -->
        </div>

        <div class="legend-box">
          <div class="legend-item"><div class="legend-color" style="background: #dcfce7; border-color: #86efac;"></div> ${l('legend_answered')}</div>
          <div class="legend-item"><div class="legend-color" style="background: #fef08a; border-color: #facc15;"></div> ${l('legend_doubtful')}</div>
          <div class="legend-item"><div class="legend-color" style="background: #f8fafc; border-color: #cbd5e1;"></div> ${l('legend_unanswered')}</div>
        </div>

        <button class="btn btn-danger" style="width: 100%; justify-content: center; padding: 12px;" onclick="promptSubmitExam()">
          🏁 Selesai Ujian & Kirim Jawaban
        </button>
      </div>
    </div>
  </div>

  <!-- View 4: Finish Confirmation Modal -->
  <div id="submitModal" class="overlay" style="display: none;">
    <div class="modal">
      <h2 class="modal-title">${l('submit_title')}</h2>
      <p class="modal-desc">${l('submit_desc')}</p>
      
      <div style="background: #f8fafc; border: 1px solid var(--border); border-radius: 8px; padding: 12px; margin-bottom: 20px; font-size: 13.5px;">
        <div style="display: flex; justify-content: space-between; margin-bottom: 6px;">
          <span>${l('answered_label')}</span> <strong id="summaryAnswered" class="text-success">0</strong>
        </div>
        <div style="display: flex; justify-content: space-between; margin-bottom: 6px;">
          <span>${l('doubtful_label')}</span> <strong id="summaryDoubtful" style="color: var(--accent);">0</strong>
        </div>
        <div style="display: flex; justify-content: space-between;">
          <span>${l('empty_label')}</span> <strong id="summaryUnanswered" class="text-danger">0</strong>
        </div>
      </div>

      <div style="display: flex; gap: 10px; justify-content: flex-end;">
        <button class="btn btn-outline" onclick="closeSubmitModal()">${l('review_again')}</button>
        <button class="btn btn-danger" onclick="submitExamFinal()">${l('confirm_finish')}</button>
      </div>
    </div>
  </div>

  <!-- View 5: Result Certificate Screen -->
  <div id="resultSection" style="display: none;">
    <div class="cert-card">
      <div class="cert-header">
        <div class="cert-seal">🏛</div>
        <h2 style="font-size: 20px; font-weight: 800; color: var(--primary-dark);">${l('gov')}</h2>
        <div style="font-size: 14px; font-weight: 600; color: var(--text-muted); margin-top: 4px;">${l('result_title')}</div>
        <div style="font-size: 12px; color: var(--text-muted);">${l('result_sub')}</div>
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px; font-size: 14px; margin-bottom: 20px; background: #f8fafc; padding: 16px; border-radius: 8px;">
        <div><strong>${l('candidate_name')}</strong> <span id="resName">-</span></div>
        <div><strong>${l('exam_number')}</strong> <span id="resNo">-</span></div>
        <div><strong>NIK:</strong> <span id="resNik">-</span></div>
        <div><strong>${l('finished_at')}</strong> <span id="resTime">-</span></div>
      </div>

      <!-- Subtest Score Cards -->
      <div class="cert-scores">
        <div class="score-card">
          <div style="font-size: 12px; font-weight: 700; color: var(--text-muted);">${l('twk')}</div>
          <div id="resTwk" class="score-val">0</div>
          <div class="score-target">${l('threshold')} 15 &middot; <span id="resTwkBadge" class="cand-badge">${l('pass')}</span></div>
        </div>

        <div class="score-card">
          <div style="font-size: 12px; font-weight: 700; color: var(--text-muted);">${l('tiu')}</div>
          <div id="resTiu" class="score-val">0</div>
          <div class="score-target">${l('threshold')} 15 &middot; <span id="resTiuBadge" class="cand-badge">${l('pass')}</span></div>
        </div>

        <div class="score-card">
          <div style="font-size: 12px; font-weight: 700; color: var(--text-muted);">${l('tkp')}</div>
          <div id="resTkp" class="score-val">0</div>
          <div class="score-target">${l('threshold')} 18 &middot; <span id="resTkpBadge" class="cand-badge">${l('pass')}</span></div>
        </div>
      </div>

      <!-- Total Banner -->
      <div class="total-banner">
        <div style="font-size: 14px; opacity: 0.9; text-transform: uppercase; letter-spacing: 1px;">${l('total_score')}</div>
        <div id="resTotal" class="total-score-num">0</div>
        <div>
          <span id="resPassBadge" class="pass-badge passed">${l('meets')}</span>
        </div>
        <div style="margin-top: 10px; font-size: 14px; font-weight: 600;">
          ${l('rank_label')} <span id="resRankDisplay" style="color: #facc15; font-size: 18px;">#1</span> ${l('of')} <span id="resTotalCand">1</span> ${l('candidates')}
        </div>
      </div>

      <div style="display: flex; gap: 12px; justify-content: center; margin-top: 24px;">
        <button class="btn btn-outline" onclick="viewLeaderboardModal()">${l('view_board')}</button>
        <button class="btn btn-primary" onclick="resetToLogin()">${l('try_other')}</button>
      </div>
    </div>
  </div>

  <!-- View 6: Leaderboard Modal -->
  <div id="leaderboardModal" class="overlay" style="display: none;">
    <div class="modal" style="max-width: 860px;">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
        <h2 class="modal-title" style="margin: 0;">${l('board_title')}</h2>
        <button class="btn btn-outline" style="padding: 4px 10px;" onclick="closeLeaderboardModal()">${l('close')}</button>
      </div>
      <p class="modal-desc">${l('board_desc')}</p>
      
      <div class="table-box">
        <table>
          <thead>
            <tr>
              <th>${l('th_rank')}</th>
              <th>${l('th_exam_no')}</th>
              <th>${l('th_name')}</th>
              <th>NIK</th>
              <th>TWK</th>
              <th>TIU</th>
              <th>TKP</th>
              <th>Total</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody id="leaderboardTbody">
            <tr><td colspan="9" style="text-align: center;">${l('loading_data')}</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>

</main>

<script>
  // Lines in the page locale, and that locale on every API call
  // (SetLocaleMiddleware reads Accept-Language).
  const T = $script;
  const LANG = '${escape(locale)}';
  const nativeFetch = window.fetch.bind(window);
  window.fetch = (url, options = {}) => nativeFetch(url, {
    ...options,
    headers: { 'Accept-Language': LANG, ...(options.headers || {}) },
  });

  // App State
  let sessionToken = null;
  let activeSession = null;
  let candidateData = null;
  let questions = [];
  let userAnswers = {}; // { questionId: { selectedOption, isDoubtful } }
  let currentQIndex = 0;
  let timerInterval = null;

  // Persistent client device ID in localStorage to survive browser reloads (F5) without lock conflict
  function getDeviceId() {
    try {
      let id = localStorage.getItem('cat_exam_device_id');
      if (!id) {
        id = 'pc_' + Math.random().toString(36).substring(2, 9) + '_' + Date.now().toString(36);
        localStorage.setItem('cat_exam_device_id', id);
      }
      return id;
    } catch (e) {
      return 'pc_client_' + Math.random().toString(36).substring(2, 9);
    }
  }

  let lastDeviceId = getDeviceId();

  // Quick fill candidate
  function fillCandidate(nik, examNo) {
    document.getElementById('loginNik').value = nik;
    document.getElementById('loginExamNo').value = examNo;
  }

  // Login handler
  async function handleCandidateLogin() {
    const nik = document.getElementById('loginNik').value.trim();
    const examNo = document.getElementById('loginExamNo').value.trim();
    const errBox = document.getElementById('loginError');
    errBox.style.display = 'none';

    if (!nik || !examNo) {
      errBox.innerText = T.fill_credentials;
      errBox.style.display = 'block';
      return;
    }

    try {
      const resp = await fetch('/api/exam/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          nik: nik,
          exam_number: examNo,
          device_id: lastDeviceId,
          duration_minutes: 30
        })
      });

      const data = await resp.json();

      if (resp.status === 409) {
        // Device conflict
        document.getElementById('conflictMessage').innerText = data.message;
        document.getElementById('conflictModal').style.display = 'flex';
        return;
      }

      if (!resp.ok) {
        errBox.innerText = data.message || T.login_failed;
        errBox.style.display = 'block';
        return;
      }

      if (data.status === 'completed') {
        alert(data.message || T.already_done);
        loadResultView(data.session ? data.session.id : null);
        return;
      }

      // Successful login or resume
      sessionToken = data.token;
      activeSession = data.session;
      candidateData = data.candidate;
      if (data.answers) {
        userAnswers = data.answers;
      }

      // Start Exam Screen
      document.getElementById('loginSection').style.display = 'none';
      await startExamUI();

    } catch (e) {
      errBox.innerText = T.connect_failed + e.message;
      errBox.style.display = 'block';
    }
  }

  function closeConflictModal() {
    document.getElementById('conflictModal').style.display = 'none';
  }

  async function simulateProctorReset() {
    const nik = document.getElementById('loginNik').value.trim();
    try {
      const resp = await fetch('/api/exam/proctor/reset-lock', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          nik: nik,
          reason: T.reset_reason
        })
      });
      const data = await resp.json();
      alert(T.reset_done);
      closeConflictModal();
      await handleCandidateLogin();
    } catch (e) {
      alert(T.reset_failed + e.message);
    }
  }

  // Start Exam View
  async function startExamUI() {
    // Populate Candidate Bar
    document.getElementById('candNameDisplay').innerText = candidateData.name;
    document.getElementById('candNikDisplay').innerText = candidateData.nik;
    document.getElementById('candNoDisplay').innerText = candidateData.exam_number;

    document.getElementById('candidateBar').style.display = 'flex';
    document.getElementById('headerTimerGroup').style.display = 'flex';
    document.getElementById('examSection').style.display = 'block';

    // Start server countdown timer
    startTimer(activeSession.remaining_seconds);

    // Fetch questions
    await fetchQuestions();
  }

  async function fetchQuestions() {
    try {
      const resp = await fetch('/api/exam/questions', {
        headers: { 'Authorization': 'Bearer ' + sessionToken }
      });
      const data = await resp.json();
      questions = data.questions || [];
      renderPalette();
      renderCurrentQuestion();
    } catch (e) {
      alert(T.load_questions_failed + e.message);
    }
  }

  // Drift-Proof Wall-Clock Timer countdown
  function startTimer(secondsLeft) {
    if (timerInterval) clearInterval(timerInterval);

    const targetEndTime = Date.now() + (secondsLeft * 1000);
    const timerElem = document.getElementById('timerText');

    function updateDisplay() {
      const now = Date.now();
      const remain = Math.max(0, Math.round((targetEndTime - now) / 1000));

      if (remain <= 0) {
        clearInterval(timerInterval);
        timerElem.innerText = '00:00:00';
        timerElem.style.color = '#ef4444';
        alert(T.time_over_auto);
        submitExamFinal();
        return;
      }

      const h = Math.floor(remain / 3600).toString().padStart(2, '0');
      const m = Math.floor((remain % 3600) / 60).toString().padStart(2, '0');
      const s = Math.floor(remain % 60).toString().padStart(2, '0');
      timerElem.innerText = h + ':' + m + ':' + s;

      if (remain < 300) {
        timerElem.style.color = '#ef4444'; // Red < 5 mins
      } else if (remain < 600) {
        timerElem.style.color = '#f59e0b'; // Amber < 10 mins
      }
    }

    updateDisplay();
    timerInterval = setInterval(updateDisplay, 1000);
  }

  // Render question palette
  function renderPalette() {
    const grid = document.getElementById('paletteGrid');
    grid.innerHTML = '';

    let answeredCount = 0;

    questions.forEach((q, idx) => {
      const btn = document.createElement('button');
      btn.className = 'palette-btn';
      if (idx === currentQIndex) btn.classList.add('active');

      const ans = userAnswers[q.question_id];
      if (ans && ans.selected_option) {
        answeredCount++;
        if (ans.is_doubtful) {
          btn.classList.add('doubtful');
        } else {
          btn.classList.add('answered');
        }
        btn.innerHTML = '<span>' + (idx + 1) + '</span><span class="palette-choice">' + ans.selected_option + '</span>';
      } else {
        btn.innerHTML = '<span>' + (idx + 1) + '</span>';
      }

      btn.onclick = () => {
        currentQIndex = idx;
        renderPalette();
        renderCurrentQuestion();
      };

      grid.appendChild(btn);
    });

    document.getElementById('progressSummary').innerText = answeredCount + ' / ' + questions.length + ' ' + T.answered_suffix;
  }

  // Render current question
  function renderCurrentQuestion() {
    if (!questions.length) return;
    const q = questions[currentQIndex];

    document.getElementById('currentCategoryPill').innerText = q.category;
    document.getElementById('qNumberDisplay').innerText = T.question_of.replace(':n', currentQIndex + 1).replace(':total', questions.length);
    document.getElementById('qTextDisplay').innerText = q.question_text;

    const ans = userAnswers[q.question_id] || {};
    const selected = ans.selected_option || null;

    // Doubtful button state
    const btnDoubtful = document.getElementById('btnDoubtful');
    if (ans.is_doubtful) {
      btnDoubtful.classList.add('active');
    } else {
      btnDoubtful.classList.remove('active');
    }

    // Prev / Next button state
    document.getElementById('btnPrev').disabled = currentQIndex === 0;
    document.getElementById('btnNext').innerText = currentQIndex === questions.length - 1 ? T.finish_arrow : T.next;

    // Options rendering
    const container = document.getElementById('optionsContainer');
    container.innerHTML = '';

    q.options.forEach(opt => {
      const item = document.createElement('div');
      item.className = 'option-item' + (selected === opt.id ? ' selected' : '');

      item.innerHTML = `
        <div class="opt-letter">\${opt.id}</div>
        <div class="opt-text">\${opt.text}</div>
      `;

      item.onclick = () => selectOption(q.question_id, opt.id);
      container.appendChild(item);
    });
  }

  // Select Option & Trigger Real-Time Auto-Save
  async function selectOption(questionId, optionId) {
    const existing = userAnswers[questionId] || {};
    const isDoubtful = existing.is_doubtful || false;

    userAnswers[questionId] = {
      selected_option: optionId,
      is_doubtful: isDoubtful
    };

    renderPalette();
    renderCurrentQuestion();

    // Trigger instant auto-save to server
    await autoSaveAnswer(questionId, optionId, isDoubtful);
  }

  // Toggle doubtful status
  async function toggleDoubtful() {
    const q = questions[currentQIndex];
    const ans = userAnswers[q.question_id] || { selected_option: '' };
    ans.is_doubtful = !ans.is_doubtful;
    userAnswers[q.question_id] = ans;

    renderPalette();
    renderCurrentQuestion();

    if (ans.selected_option) {
      await autoSaveAnswer(q.question_id, ans.selected_option, ans.is_doubtful);
    }
  }

  // Navigate question
  function navigateQuestion(delta) {
    const nextIdx = currentQIndex + delta;
    if (nextIdx >= 0 && nextIdx < questions.length) {
      currentQIndex = nextIdx;
      renderPalette();
      renderCurrentQuestion();
    } else if (nextIdx >= questions.length) {
      promptSubmitExam();
    }
  }

  // Auto-Save Endpoint caller
  async function autoSaveAnswer(questionId, selectedOption, isDoubtful) {
    const micro = document.getElementById('saveMicroIndicator');
    micro.innerText = T.saving;
    micro.style.color = '#d97706';

    try {
      const t0 = performance.now();
      const resp = await fetch('/api/exam/answer', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + sessionToken
        },
        body: JSON.stringify({
          question_id: questionId,
          selected_option: selectedOption,
          is_doubtful: isDoubtful,
          idempotency_key: 'idem_' + questionId + '_' + Date.now()
        })
      });

      const elapsed = Math.round(performance.now() - t0);

      if (resp.status === 410) {
        alert(T.time_over);
        submitExamFinal();
        return;
      }

      micro.innerText = T.saved + ' (' + elapsed + 'ms)';
      micro.style.color = '#16a34a';

      const syncStatus = document.getElementById('syncStatus');
      syncStatus.innerText = T.saved + ' (' + elapsed + 'ms)';

    } catch (e) {
      micro.innerText = T.save_failed;
      micro.style.color = '#dc2626';
    }
  }

  // Submit Exam Prompt
  function promptSubmitExam() {
    let answered = 0;
    let doubtful = 0;

    questions.forEach(q => {
      const ans = userAnswers[q.question_id];
      if (ans && ans.selected_option) {
        answered++;
        if (ans.is_doubtful) doubtful++;
      }
    });

    const confident = answered - doubtful;
    const unanswered = questions.length - answered;

    document.getElementById('summaryAnswered').innerText = confident + ' (Pasti)';
    document.getElementById('summaryDoubtful').innerText = doubtful;
    document.getElementById('summaryUnanswered').innerText = unanswered;

    document.getElementById('submitModal').style.display = 'flex';
  }

  function closeSubmitModal() {
    document.getElementById('submitModal').style.display = 'none';
  }

  // Final submission & Instant Scoring
  async function submitExamFinal() {
    closeSubmitModal();
    if (timerInterval) clearInterval(timerInterval);

    try {
      const resp = await fetch('/api/exam/finish', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + sessionToken
        }
      });

      const data = await resp.json();

      document.getElementById('examSection').style.display = 'none';
      document.getElementById('headerTimerGroup').style.display = 'none';
      displayResult(data);

    } catch (e) {
      alert(T.finish_failed + e.message);
    }
  }

  // Display Score Certificate
  function displayResult(data) {
    document.getElementById('resultSection').style.display = 'block';

    const c = data.candidate || candidateData || {};
    document.getElementById('resName').innerText = c.name || '-';
    document.getElementById('resNo').innerText = c.exam_number || '-';
    document.getElementById('resNik').innerText = c.nik || '-';
    document.getElementById('resTime').innerText = new Date(data.submitted_at || Date.now()).toLocaleString('id-ID');

    const sc = data.scores || {};
    document.getElementById('resTwk').innerText = sc.twk ?? 0;
    document.getElementById('resTiu').innerText = sc.tiu ?? 0;
    document.getElementById('resTkp').innerText = sc.tkp ?? 0;
    document.getElementById('resTotal').innerText = sc.total ?? 0;

    const twkBadge = document.getElementById('resTwkBadge');
    twkBadge.innerText = sc.twk_passed ? T.pass : T.fail;
    twkBadge.style.color = sc.twk_passed ? '#15803d' : '#b91c1c';

    const tiuBadge = document.getElementById('resTiuBadge');
    tiuBadge.innerText = sc.tiu_passed ? T.pass : T.fail;
    tiuBadge.style.color = sc.tiu_passed ? '#15803d' : '#b91c1c';

    const tkpBadge = document.getElementById('resTkpBadge');
    tkpBadge.innerText = sc.tkp_passed ? T.pass : T.fail;
    tkpBadge.style.color = sc.tkp_passed ? '#15803d' : '#b91c1c';

    const passBanner = document.getElementById('resPassBadge');
    if (sc.passing_grade_met) {
      passBanner.className = 'pass-badge passed';
      passBanner.innerText = T.meets_full;
    } else {
      passBanner.className = 'pass-badge failed';
      passBanner.innerText = T.not_meets;
    }

    const rawRank = data.ranking;
    const rankInfo = typeof rawRank === 'object' && rawRank !== null
        ? rawRank
        : { rank: rawRank || 1, total_participants: 1 };
    document.getElementById('resRankDisplay').innerText = '#' + (rankInfo.rank || 1);
    document.getElementById('resTotalCand').innerText = rankInfo.total_participants || 1;
  }

  async function loadResultView(sessionId) {
    if (!sessionId) return;
    try {
      const resp = await fetch('/api/exam/result/' + sessionId);
      const data = await resp.json();
      document.getElementById('loginSection').style.display = 'none';
      displayResult(data);
    } catch (e) {
      alert(T.load_result_failed + e.message);
    }
  }

  // Leaderboard Modal
  async function viewLeaderboardModal() {
    document.getElementById('leaderboardModal').style.display = 'flex';
    const tbody = document.getElementById('leaderboardTbody');
    tbody.innerHTML = '<tr><td colspan="9" style="text-align: center;">' + T.loading_board + '</td></tr>';

    try {
      const resp = await fetch('/api/exam/leaderboard');
      const data = await resp.json();
      const list = data.leaderboard || [];

      if (!list.length) {
        tbody.innerHTML = '<tr><td colspan="9" style="text-align: center;">' + T.board_empty + '</td></tr>';
        return;
      }

      tbody.innerHTML = '';
      list.forEach(row => {
        const tr = document.createElement('tr');
        tr.innerHTML = `
          <td><strong>#\${row.rank}</strong></td>
          <td><code>\${row.exam_number}</code></td>
          <td><strong>\${row.candidate_name}</strong></td>
          <td>\${row.masked_nik}</td>
          <td>\${row.score_twk}</td>
          <td>\${row.score_tiu}</td>
          <td>\${row.score_tkp}</td>
          <td><strong style="color: var(--primary);">\${row.total_score}</strong></td>
          <td><span class="cand-badge" style="color: \${row.passing_grade_met ? '#15803d' : '#b91c1c'};">\${row.passing_grade_met ? T.pass : T.fail}</span></td>
        `;
        tbody.appendChild(tr);
      });
    } catch (e) {
      tbody.innerHTML = '<tr><td colspan="9" style="text-align: center; color: red;">' + T.board_failed + '</td></tr>';
    }
  }

  function closeLeaderboardModal() {
    document.getElementById('leaderboardModal').style.display = 'none';
  }

  function resetToLogin() {
    location.reload();
  }
</script>

</body>
</html>
''';
}

/// HTML-escapes [value].
String escape(String value) =>
    const HtmlEscape(HtmlEscapeMode.element)
        .convert(value)
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
