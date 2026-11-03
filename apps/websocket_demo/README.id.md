<!-- source: README.md sha256:6b3028f399d6 -->
# Daravel WebSocket Demo

[English](README.md) · Bahasa Indonesia

Proyek contoh sederhana, bersih, dan lengkap yang mendemonstrasikan fitur **WebSocket** dan **Broadcasting Antar-Isolate** pada framework **Daravel** (Laravel-style framework for Dart).

---

## Fitur Utama (Key Features)

1. **`router.ws('/ws/echo', ...)`**:
   - Contoh WebSocket duplex 1-to-1 paling sederhana.
   - Menerima pesan teks dan mengembalikannya dengan format `Echo: <pesan>`.

2. **`router.ws('/ws/chat/{room}', ...)`**:
   - WebSocket dinamis dengan parameter route `{room}`.
   - Menggunakan `Broadcast.pipe(socket, ['chat.$room'], onMessage: ...)` untuk menyambungkan socket langsung ke channel broadcast koordinator.
   - Saat ada pesan dikirim dari salah satu client, pesan tersebut di-publish ke semua worker isolate via `Broadcast.publish('chat.$room', message)`.
   - Mengisolasi pesan berdasarkan room (pesan di room `general` tidak akan bocor ke room `tech`).
   - Unsubscribe dan pembersihan resource otomatis saat client disconnect.

3. **HTTP REST to WebSocket Push (`POST /api/chat/{room}/broadcast`)**:
   - Contoh integrasi controller backend / background job / webhook yang mendorong notifikasi real-time ke client WebSocket yang sedang aktif melalui `Broadcast.publish()`.

4. **Interactive Web Client UI (`GET /`)**:
   - Web client interaktif siap pakai yang disajikan langsung oleh server tanpa perlu build tool (npm/vite) tambahan.
   - Fitur UI:
     - Ganti room chat secara dinamis
     - Kirim & terima pesan chat real-time
     - Tombol simulasi HTTP REST Push untuk melihat notifikasi muncul langsung di WebSocket
     - Uji coba WebSocket Echo
     - Indikator status koneksi (Connected / Connecting / Disconnected)

5. **Automated Test Suite (`test/websocket_demo_test.dart`)**:
   - Pengujian menyeluruh yang mencakup:
     - Upgrade rejection (HTTP 426 Upgrade Required untuk request non-WebSocket)
     - Echo WebSocket
     - Multi-client room broadcasting
     - Channel isolation antar room
     - HTTP REST publish ke WebSocket client
     - Penyajian halaman HTML client

---

## Struktur Folder (Project Structure)

```text
apps/websocket_demo/
├── bin/
│   ├── dartisan.dart             # Project CLI runner
│   └── server.dart               # Server HTTP & WebSocket entrypoint
├── bootstrap/
│   ├── app.dart                  # Konfigurasi aplikasi Daravel
│   └── commands.dart             # Registry custom console commands
├── resources/
│   └── views/
│       └── chat_page.dart        # HTML & Vanilla JS client interface
├── routes/
│   ├── api.dart                  # HTTP API routes (POST /api/chat/{room}/broadcast)
│   └── web.dart                  # Web & WebSocket routes (GET /, WS /ws/echo, WS /ws/chat/{room})
├── test/
│   └── websocket_demo_test.dart  # Unit & integration test suite
├── .env.example                  # Template environment variables
├── pubspec.yaml                  # Workspace package configuration
└── README.md                     # Dokumentasi panduan
```

---

## Cara Menjalankan Server (How to Run)

### 0. Siapkan `.env`

```bash
cd apps/websocket_demo
cp .env.example .env
dart run bin/dartisan.dart key:generate
```

### 1. Jalankan Server

Masuk ke folder workspace daravel atau langsung ke sub-folder:

```bash
# Dari root repositori:
dart run apps/websocket_demo/bin/server.dart

# Atau masuk ke folder apps/websocket_demo:
cd apps/websocket_demo
dart run bin/server.dart
```

Server akan mulai mendengarkan pada:
```text
[INFO] Daravel server listening on http://127.0.0.1:8000
```

### 2. Buka Client di Browser

Buka URL berikut di browser Anda:
```text
http://127.0.0.1:8000
```

- Anda bisa membuka dua tab browser sekaligus (misalnya Tab 1 sebagai `User_1` dan Tab 2 sebagai `User_2`) di room `general` untuk mencoba chat dua arah secara langsung.
- Klik tombol **"POST /api/chat/general/broadcast"** untuk mensimulasikan server backend yang mendorong event eksternal ke semua client WebSocket yang terhubung.

Kedua tab harus terhubung ke server yang sama. Broadcast menyeberang antar-isolate
dalam satu proses (`--isolates=N`); dua proses terpisah, misalnya satu di port 8000
dan satu di port 8001, butuh `daravel_redis` dan `withRedis()` agar pesannya
tersambung.

---

## Cara Menjalankan Test (Running Tests)

Jalankan rangkaian tes otomatis menggunakan runner `dart test`:

```bash
# Menjalankan test websocket demo
dart test apps/websocket_demo/test/websocket_demo_test.dart
```

Semua pengujian akan memverifikasi koneksi socket nyata, broadcast antar-client, isolasi channel, dan penolakan request plain HTTP (status 426).

---

## Contoh Kode Inti (Core Snippets)

### 1. Mendefinisikan WebSocket Route (`routes/web.dart`)

```dart
import 'dart:convert';
import 'dart:io';
import 'package:daravel/daravel.dart';

void webRoutes(Router router) {
  // Echo Route
  router.ws('/ws/echo', (WebSocket socket, Request request) async {
    try {
      await for (final message in socket) {
        socket.add('Echo: $message');
      }
    } catch (_) {
      // Socket dropped
    } finally {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
  });

  // Room Chat Route dengan Inter-Isolate Broadcast
  router.ws('/ws/chat/{room}', (WebSocket socket, Request request) async {
    final rawRoom = request.param<String>('room');
    final room = rawRoom.trim().isEmpty ? 'general' : rawRoom.trim();
    final channel = 'chat.$room';

    // Sambungkan socket ke channel broadcast
    await Broadcast.pipe(
      socket,
      [channel],
      onMessage: (message) async {
        if (message == null) return;
        if (message is String && message.trim().isEmpty) return;
        try {
          // Forward pesan client ke semua isolate & socket di room ini
          await Broadcast.publish(channel, message);
        } catch (_) {
          // Coordinator unavailable or socket dropped
        }
      },
    );
  });
}
```

### 2. HTTP Controller / API Mendorong Pesan ke WebSocket (`routes/api.dart`)

```dart
import 'dart:convert';
import 'package:daravel/daravel.dart';

void apiRoutes(Router router) {
  router.post('/chat/{room}/broadcast', (Request request) async {
    final room = request.param<String>('room');
    final data = await request.all();

    final payload = jsonEncode({
      'type': 'broadcast',
      'room': room,
      'sender': data['sender'] ?? 'System',
      'text': data['message'] ?? 'Notice',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    // Publish pesan ke koordinator agar disalurkan ke semua worker isolate
    final delivered = await Broadcast.publish('chat.$room', payload);

    return Response.json({
      'status': 'published',
      'delivered_to_isolates': delivered,
    });
  });
}
```
