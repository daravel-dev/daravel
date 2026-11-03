import 'dart:convert';

import 'package:daravel/daravel.dart'
    show daravelFaviconDataUri, daravelLogoDataUri;

/// Renders the interactive WebSocket demo client HTML page.
String chatPage({
  required String appName,
  required String environment,
  required String frameworkVersion,
}) {
  final name = htmlEscape.convert(appName);

  return '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$name - Daravel WebSocket</title>
  <link rel="icon" type="image/png" href="$daravelFaviconDataUri">
  <style>
    :root {
      --bg: #0b0d12;
      --panel: #12151c;
      --panel-2: #171b24;
      --line: #232936;
      --text: #e6e8ee;
      --muted: #9aa3b5;
      --accent: #ff2d20;
      --accent-hover: #ff4d40;
      --ok: #22c55e;
      --warn: #eab308;
      --err: #ef4444;
      --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f7f7f8;
        --panel: #ffffff;
        --panel-2: #f1f2f5;
        --line: #e4e6ea;
        --text: #16181d;
        --muted: #5f6675;
      }
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }
    .container {
      max-width: 1000px;
      margin: 0 auto;
      padding: 32px 20px;
      width: 100%;
      flex: 1;
      display: flex;
      flex-direction: column;
      gap: 24px;
    }
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 16px;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--line);
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .brand img {
      width: 36px;
      height: 36px;
      border-radius: 8px;
    }
    .brand h1 {
      font-size: 20px;
      font-weight: 700;
    }
    .badge {
      font-family: var(--mono);
      font-size: 12px;
      padding: 4px 10px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: var(--panel-2);
      color: var(--muted);
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    .badge-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--muted);
    }
    .badge-dot.connected { background: var(--ok); box-shadow: 0 0 0 3px rgba(34,197,94,0.2); }
    .badge-dot.connecting { background: var(--warn); }
    .badge-dot.disconnected { background: var(--err); }

    .main-grid {
      display: grid;
      grid-template-columns: 1fr 340px;
      gap: 20px;
      flex: 1;
    }
    @media (max-width: 820px) {
      .main-grid { grid-template-columns: 1fr; }
    }

    .card {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 12px;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .card-header {
      padding: 14px 18px;
      background: var(--panel-2);
      border-bottom: 1px solid var(--line);
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-weight: 600;
      font-size: 14px;
    }
    .card-body {
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 14px;
      flex: 1;
    }

    /* Chat Messages Box */
    .chat-messages {
      flex: 1;
      min-height: 320px;
      max-height: 480px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 10px;
      padding: 16px;
      background: var(--panel);
      scroll-behavior: smooth;
    }
    .message-bubble {
      padding: 10px 14px;
      border-radius: 10px;
      background: var(--panel-2);
      border: 1px solid var(--line);
      max-width: 85%;
      font-size: 14px;
    }
    .message-bubble.mine {
      align-self: flex-end;
      background: #ff2d2015;
      border-color: #ff2d2050;
    }
    .message-bubble.system {
      align-self: center;
      font-size: 12px;
      background: transparent;
      border: 1px dashed var(--line);
      color: var(--muted);
      text-align: center;
      max-width: 95%;
    }
    .message-bubble.broadcast {
      align-self: center;
      background: #3b82f615;
      border-color: #3b82f650;
      color: var(--text);
      max-width: 90%;
    }
    .message-meta {
      font-size: 11px;
      color: var(--muted);
      margin-bottom: 4px;
      display: flex;
      gap: 8px;
      justify-content: space-between;
    }
    .message-sender {
      font-weight: 600;
      color: var(--accent);
    }
    .message-sender.broadcast {
      color: #3b82f6;
    }

    /* Form controls */
    .input-row {
      display: flex;
      gap: 8px;
    }
    input, button, select {
      font: inherit;
      border-radius: 8px;
      outline: none;
    }
    input, select {
      background: var(--panel-2);
      border: 1px solid var(--line);
      color: var(--text);
      padding: 8px 12px;
      font-size: 14px;
    }
    input:focus, select:focus {
      border-color: var(--accent);
    }
    button {
      background: var(--accent);
      color: #fff;
      border: none;
      padding: 8px 16px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s ease;
    }
    button:hover:not(:disabled) {
      background: var(--accent-hover);
    }
    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    button.secondary {
      background: var(--panel-2);
      color: var(--text);
      border: 1px solid var(--line);
    }
    button.secondary:hover:not(:disabled) {
      background: var(--line);
    }

    /* Sidebar sections */
    .control-section {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .control-label {
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      color: var(--muted);
    }
    .code-tag {
      font-family: var(--mono);
      font-size: 12px;
      background: var(--panel-2);
      padding: 2px 6px;
      border-radius: 4px;
      color: var(--muted);
    }
    .help-text {
      font-size: 12px;
      color: var(--muted);
      line-height: 1.4;
    }

    footer {
      text-align: center;
      padding: 20px;
      font-size: 12px;
      color: var(--muted);
      border-top: 1px solid var(--line);
      margin-top: auto;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="brand">
        <img src="$daravelLogoDataUri" alt="Daravel logo">
        <div>
          <h1>$name</h1>
          <p style="font-size: 13px; color: var(--muted);">WebSocket & Inter-Isolate Broadcast Example</p>
        </div>
      </div>
      <div class="badge">
        <span class="badge-dot disconnected" id="statusDot"></span>
        <span id="statusText">Disconnected</span>
        <span style="opacity: 0.4;">|</span>
        <span>$environment</span>
      </div>
    </header>

    <div class="main-grid">
      <!-- Chat Pane -->
      <div class="card">
        <div class="card-header">
          <div>
            <span>Room: <strong id="roomDisplay">general</strong></span>
            <span class="code-tag" id="wsRouteTag">/ws/chat/general</span>
          </div>
          <button id="clearBtn" class="secondary" style="padding: 4px 10px; font-size: 12px;">Clear Log</button>
        </div>
        <div class="chat-messages" id="messagesContainer">
          <div class="message-bubble system">
            Click <strong>"Connect"</strong> to open a WebSocket connection to the Daravel server.
          </div>
        </div>
        <div style="padding: 12px 16px; border-top: 1px solid var(--line); background: var(--panel-2);">
          <form id="chatForm" class="input-row">
            <input type="text" id="messageInput" placeholder="Type a message to broadcast..." style="flex: 1;" disabled>
            <button type="submit" id="sendBtn" disabled>Send</button>
          </form>
        </div>
      </div>

      <!-- Controls & Features Sidebar -->
      <div style="display: flex; flex-direction: column; gap: 16px;">
        <!-- Connection Settings -->
        <div class="card">
          <div class="card-header">
            <span>WebSocket Settings</span>
          </div>
          <div class="card-body">
            <div class="control-section">
              <label class="control-label">Your Nickname</label>
              <input type="text" id="usernameInput" value="User_1" placeholder="Enter nickname">
            </div>
            <div class="control-section">
              <label class="control-label">Chat Room</label>
              <div class="input-row">
                <input type="text" id="roomInput" value="general" placeholder="Room name" style="flex: 1;">
              </div>
            </div>
            <div class="input-row" style="margin-top: 4px;">
              <button id="connectBtn" style="flex: 1;">Connect</button>
              <button id="disconnectBtn" class="secondary" disabled>Disconnect</button>
            </div>
            <p class="help-text">
              Demonstrates Daravel route <span class="code-tag">router.ws('/ws/chat/{room}')</span> with automatic isolate broadcast.
            </p>
          </div>
        </div>

        <!-- REST Broadcast Trigger -->
        <div class="card">
          <div class="card-header">
            <span>HTTP REST Broadcast</span>
          </div>
          <div class="card-body">
            <p class="help-text">
              Simulate an external HTTP request, scheduled job, or controller pushing a notification to this WebSocket room using <span class="code-tag">Broadcast.publish()</span>.
            </p>
            <input type="text" id="httpMsgInput" placeholder="Alert message..." value="System update: Server reload completed">
            <button id="triggerHttpBtn" class="secondary">
              POST /api/chat/<span id="httpRoomLabel">general</span>/broadcast
            </button>
            <div id="httpResult" class="help-text" style="font-family: var(--mono); color: var(--ok); min-height: 16px;"></div>
          </div>
        </div>

        <!-- Echo Route Test -->
        <div class="card">
          <div class="card-header">
            <span>Echo WebSocket Test</span>
          </div>
          <div class="card-body">
            <p class="help-text">
              Test the minimal 1-to-1 echo route <span class="code-tag">router.ws('/ws/echo')</span>:
            </p>
            <div class="input-row">
              <input type="text" id="echoInput" placeholder="Ping..." value="Hello Daravel" style="flex: 1;">
              <button id="echoBtn" class="secondary">Echo</button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <footer>
      Daravel v$frameworkVersion &bull; High-Performance Dart Web & Real-Time Framework
    </footer>
  </div>

  <script>
    (() => {
      let socket = null;
      const statusDot = document.getElementById('statusDot');
      const statusText = document.getElementById('statusText');
      const roomDisplay = document.getElementById('roomDisplay');
      const wsRouteTag = document.getElementById('wsRouteTag');
      const httpRoomLabel = document.getElementById('httpRoomLabel');
      const messagesContainer = document.getElementById('messagesContainer');
      const chatForm = document.getElementById('chatForm');
      const messageInput = document.getElementById('messageInput');
      const sendBtn = document.getElementById('sendBtn');
      const connectBtn = document.getElementById('connectBtn');
      const disconnectBtn = document.getElementById('disconnectBtn');
      const usernameInput = document.getElementById('usernameInput');
      const roomInput = document.getElementById('roomInput');
      const clearBtn = document.getElementById('clearBtn');
      const triggerHttpBtn = document.getElementById('triggerHttpBtn');
      const httpMsgInput = document.getElementById('httpMsgInput');
      const httpResult = document.getElementById('httpResult');
      const echoInput = document.getElementById('echoInput');
      const echoBtn = document.getElementById('echoBtn');

      function getWsUrl(path) {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        return `\${protocol}//\${window.location.host}\${path}`;
      }

      function updateStatus(state) {
        statusDot.className = 'badge-dot ' + state;
        statusText.textContent = state.charAt(0).toUpperCase() + state.slice(1);
        const isConnected = state === 'connected';
        messageInput.disabled = !isConnected;
        sendBtn.disabled = !isConnected;
        connectBtn.disabled = isConnected;
        disconnectBtn.disabled = !isConnected;
        roomInput.disabled = isConnected;
      }

      function addMessage(item) {
        const bubble = document.createElement('div');
        const isMine = item.sender === usernameInput.value.trim();

        if (item.type === 'system') {
          bubble.className = 'message-bubble system';
          bubble.textContent = `[System] \${item.text}`;
        } else {
          const isBroadcast = item.type === 'broadcast';
          bubble.className = 'message-bubble' + (isBroadcast ? ' broadcast' : (isMine ? ' mine' : ''));

          const meta = document.createElement('div');
          meta.className = 'message-meta';

          const sender = document.createElement('span');
          sender.className = 'message-sender' + (isBroadcast ? ' broadcast' : '');
          sender.textContent = item.sender || (isBroadcast ? 'Broadcast' : 'Anonymous');

          const time = document.createElement('span');
          time.textContent = item.timestamp || new Date().toLocaleTimeString();

          meta.appendChild(sender);
          meta.appendChild(time);

          const body = document.createElement('div');
          body.textContent = item.text || '';

          bubble.appendChild(meta);
          bubble.appendChild(body);
        }

        messagesContainer.appendChild(bubble);
        messagesContainer.scrollTop = messagesContainer.scrollHeight;
      }

      function connect() {
        if (socket) {
          try { socket.close(); } catch (_) {}
          socket = null;
        }

        const room = roomInput.value.trim() || 'general';
        roomDisplay.textContent = room;
        httpRoomLabel.textContent = room;
        const path = `/ws/chat/\${encodeURIComponent(room)}`;
        wsRouteTag.textContent = path;
        const url = getWsUrl(path);

        updateStatus('connecting');
        addMessage({
          type: 'system',
          text: `Connecting to \${url}...`
        });

        try {
          socket = new WebSocket(url);

          socket.onopen = () => {
            updateStatus('connected');
            addMessage({
              type: 'system',
              text: `Connected to room "\${room}".`
            });
            messageInput.focus();
          };

          socket.onmessage = (event) => {
            try {
              const data = JSON.parse(event.data);
              addMessage(data);
            } catch (e) {
              addMessage({
                sender: 'Server',
                text: event.data,
                timestamp: new Date().toLocaleTimeString()
              });
            }
          };

          socket.onerror = (error) => {
            addMessage({
              type: 'system',
              text: 'WebSocket error occurred.'
            });
          };

          socket.onclose = (event) => {
            updateStatus('disconnected');
            addMessage({
              type: 'system',
              text: `WebSocket closed (code: \${event.code}, reason: \${event.reason || 'normal'}).`
            });
            socket = null;
          };
        } catch (err) {
          updateStatus('disconnected');
          addMessage({
            type: 'system',
            text: `Connection failed: \${err.message}`
          });
        }
      }

      function disconnect() {
        if (socket) {
          socket.close(1000, 'User disconnected');
        }
      }

      connectBtn.addEventListener('click', connect);
      disconnectBtn.addEventListener('click', disconnect);
      roomInput.addEventListener('input', () => {
        httpRoomLabel.textContent = roomInput.value.trim() || 'general';
      });

      chatForm.addEventListener('submit', (e) => {
        e.preventDefault();
        const text = messageInput.value.trim();
        if (!text || !socket || socket.readyState !== WebSocket.OPEN) return;

        const payload = {
          type: 'chat',
          sender: usernameInput.value.trim() || 'Anonymous',
          text: text,
          timestamp: new Date().toLocaleTimeString()
        };

        socket.send(JSON.stringify(payload));
        messageInput.value = '';
      });

      clearBtn.addEventListener('click', () => {
        messagesContainer.innerHTML = '';
      });

      // HTTP REST Broadcast trigger
      triggerHttpBtn.addEventListener('click', async () => {
        const room = roomInput.value.trim() || 'general';
        const msg = httpMsgInput.value.trim() || 'Notification from HTTP POST';
        triggerHttpBtn.disabled = true;
        httpResult.textContent = 'Posting...';

        try {
          const resp = await fetch(`/api/chat/\${encodeURIComponent(room)}/broadcast`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              message: msg,
              sender: 'REST API Service'
            })
          });
          const json = await resp.json();
          httpResult.textContent = `Broadcast delivered to \${json.delivered_to_isolates} isolate(s)!`;
          setTimeout(() => { httpResult.textContent = ''; }, 4000);
        } catch (e) {
          httpResult.textContent = 'Broadcast request failed.';
          httpResult.style.color = 'var(--err)';
        } finally {
          triggerHttpBtn.disabled = false;
        }
      });

      // Simple Echo test
      echoBtn.addEventListener('click', () => {
        const text = echoInput.value.trim();
        if (!text) return;
        echoBtn.disabled = true;
        const echoSocket = new WebSocket(getWsUrl('/ws/echo'));
        echoSocket.onopen = () => {
          echoSocket.send(text);
        };
        echoSocket.onmessage = (event) => {
          addMessage({
            type: 'system',
            text: `[Echo Response] \${event.data}`
          });
          echoSocket.close();
          echoBtn.disabled = false;
        };
        echoSocket.onerror = () => {
          addMessage({
            type: 'system',
            text: '[Echo] Error connecting to /ws/echo'
          });
          echoBtn.disabled = false;
        };
        echoSocket.onclose = () => {
          echoBtn.disabled = false;
        };
      });

      // Auto-connect on page load
      connect();
    })();
  </script>
</body>
</html>
''';
}
