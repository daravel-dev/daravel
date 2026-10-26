// Laravel Echo + pusher-js (the real npm packages) against a Pusher
// protocol server. MODE=daravel runs every scenario against Daravel;
// MODE=listen waits for one event on a public channel (Laravel or Daravel
// publishes it) and prints it.
import Echo from 'laravel-echo';
import Pusher from 'pusher-js';

const { HOST = '127.0.0.1', PORT, KEY, MODE = 'daravel', API = `http://127.0.0.1:${PORT}` } = process.env;
Pusher.logToConsole = false;

function echo(token) {
  return new Echo({
    broadcaster: 'reverb',
    key: KEY,
    wsHost: HOST,
    wsPort: Number(PORT),
    wssPort: Number(PORT),
    forceTLS: false,
    enabledTransports: ['ws'],
    authEndpoint: `${API}/broadcasting/auth`,
    auth: { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' } },
    Pusher,
  });
}

const timeout = (ms, what) =>
  new Promise((_, reject) => setTimeout(() => reject(new Error(`timeout: ${what}`)), ms));
const within = (promise, what, ms = 5000) => Promise.race([promise, timeout(ms, what)]);
const subscribed = (channel) => new Promise((resolve) => channel.subscribed(resolve));
const post = (path, headers = {}) => fetch(`${API}/api${path}`, { method: 'POST', headers });
const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` ${JSON.stringify(detail)}` : ''}`);
};

async function daravel() {
  const teo = echo('user-1');
  const ana = echo('user-2');

  // 1. Public channel, a custom event name (broadcastAs).
  const news = teo.channel('news');
  await within(subscribed(news), 'subscribe news');
  const published = new Promise((resolve) => news.listen('.published', resolve));
  await post('/publish');
  check('public channel', (await within(published, 'published')).title === 'Hello from Daravel');

  // 2. Private channel through /broadcasting/auth; toOthers leaves Teo out.
  const teoOrders = teo.private('orders.7');
  const anaOrders = ana.private('orders.7');
  await within(Promise.all([subscribed(teoOrders), subscribed(anaOrders)]), 'subscribe orders');
  let teoGotIt = false;
  teoOrders.listen('OrderShipped', () => { teoGotIt = true; });
  const anaShipped = new Promise((resolve) => anaOrders.listen('OrderShipped', resolve));
  await post('/ship/7', { Authorization: 'Bearer user-1', 'X-Socket-ID': teo.socketId() });
  const shipped = await within(anaShipped, 'OrderShipped');
  await new Promise((r) => setTimeout(r, 500));
  check('private channel (App\\Events\\OrderShipped)', shipped.status === 'shipped', shipped);
  check('toOthers (X-Socket-ID)', !teoGotIt);

  // 3. Whisper (client event) from Teo to Ana.
  const whisper = new Promise((resolve) => anaOrders.listenForWhisper('typing', resolve));
  teoOrders.whisper('typing', { who: 'teo' });
  check('whisper', (await within(whisper, 'whisper')).who === 'teo');

  // 4. Presence: here, joining, leaving.
  const here = new Promise((resolve) => teo.join('chat.1').here(resolve));
  const teoHere = await within(here, 'here');
  check('presence here', teoHere.length === 1 && teoHere[0].name === 'Teo', teoHere);
  const joining = new Promise((resolve) => teo.join('chat.1').joining(resolve));
  const leaving = new Promise((resolve) => teo.join('chat.1').leaving(resolve));
  const anaHere = await within(new Promise((resolve) => ana.join('chat.1').here(resolve)), 'ana here');
  check('presence joining', (await within(joining, 'joining')).name === 'Ana');
  check('presence members', anaHere.map((u) => u.name).sort().join(',') === 'Ana,Teo', anaHere);
  ana.leave('chat.1');
  check('presence leaving', (await within(leaving, 'leaving')).name === 'Ana');

  // 5. A notification on the user's private channel.
  const notification = new Promise((resolve) => teo.private('App.Models.User.1').notification(resolve));
  await within(subscribed(teo.private('App.Models.User.1')), 'subscribe user channel');
  await post('/notify');
  const n = await within(notification, 'notification');
  check('notification', n.text === 'Welcome!' && n.type === 'App\\Notifications\\Welcome' && !!n.id, n);

  // 6. Ana may not listen to Teo's channel: the auth endpoint refuses.
  const refused = await within(
    new Promise((resolve) => ana.private('App.Models.User.1').error(resolve)),
    'auth error',
  );
  check('authorization refused', refused.status === 403, refused);

  teo.disconnect();
  ana.disconnect();
}

async function listen() {
  const client = echo('user-1');
  const channel = client.channel(process.env.CHANNEL ?? 'news');
  await within(subscribed(channel), 'subscribe', 15000);
  console.log('READY');
  const event = await within(
    new Promise((resolve) => channel.listen(process.env.EVENT, resolve)),
    process.env.EVENT,
    60000,
  );
  check(`received ${process.env.EVENT}`, true, event);
  client.disconnect();
}

try {
  await (MODE === 'listen' ? listen() : daravel());
} catch (error) {
  check('run', false, String(error));
}
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
