import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {access, readFile} from 'node:fs/promises';
import net from 'node:net';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import WebSocket from 'ws';

const root = fileURLToPath(new URL('../', import.meta.url));
const binary = process.env.SWIFTSCRAPER_BINARY ?? resolve(root, '.build/debug/swift-scraper');
const reservation = net.createServer();
reservation.listen(0, '127.0.0.1');
await once(reservation, 'listening');
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
const server = spawn(binary, ['--bidi-server', '--bidi-port', String(port)], {cwd: root, stdio: ['ignore', 'ignore', 'pipe']});
const sockets = [];
let tokenFile;

function within(promise, milliseconds = 5000) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Test timed out')), milliseconds);
  })]).finally(() => clearTimeout(timer));
}

try {
  tokenFile = await within(new Promise((resolve, reject) => {
    let log = '';
    server.on('error', reject);
    server.on('exit', () => reject(new Error('Server exited before listening')));
    server.stderr.on('data', chunk => {
      log += chunk;
      const match = log.match(/BiDi token file: (.+)/);
      if (match && log.includes('BiDi server listening:')) resolve(match[1].trim());
    });
  }), 15000);
  const token = (await readFile(tokenFile, 'utf8')).trim();
  const url = `ws://127.0.0.1:${port}/session`;
  async function connect() {
    const socket = new WebSocket(url, {headers: {Authorization: `Bearer ${token}`}});
    sockets.push(socket);
    await within(once(socket, 'open'));
    return socket;
  }
  async function close(socket) {
    const closed = once(socket, 'close');
    socket.close();
    await within(closed);
  }

  // Unauthenticated TCP clients count towards the limit and have a handshake deadline.
  const tcp = [];
  for (let i = 0; i < 4; i++) {
    const socket = net.createConnection({host: '127.0.0.1', port});
    tcp.push(socket);
    sockets.push(socket);
    await within(once(socket, 'connect'));
  }
  const extra = new WebSocket(url, {headers: {Authorization: `Bearer ${token}`}});
  sockets.push(extra);
  await assert.rejects(within(once(extra, 'open')), error => error.message !== 'Test timed out');
  await within(Promise.all(tcp.map(socket => once(socket, 'close'))), 13000);
  console.log('PASS: TCP connection limit and handshake deadline');

  // A freed connection slot must be usable again.
  const socket = await connect();
  const response = once(socket, 'message');
  socket.send(JSON.stringify({id: 1, method: 'session.status'}));
  assert.equal(JSON.parse(String((await within(response))[0])).type, 'success');
  await close(socket);

  // Exercise normal Puppeteer and raw BiDi operations with the token file.
  const client = spawn(process.execPath, ['scripts/puppeteer-bidi-p1-smoke.mjs'], {
    cwd: root, stdio: ['ignore', 'ignore', 'pipe'],
    env: {...process.env, SWIFTSCRAPER_BIDI_ENDPOINT: url, SWIFTSCRAPER_BIDI_TOKEN_FILE: ''},
  });
  let clientError = '';
  client.stderr.on('data', chunk => { clientError += chunk; });
  try {
    const [code] = await within(once(client, 'exit'), 60000);
    assert.equal(code, 0, `Puppeteer smoke failed: ${clientError}`);
  } finally { if (client.exitCode === null) client.kill('SIGKILL'); }
  console.log('PASS: authenticated Puppeteer P1 smoke with automatic token discovery');

  const large = await connect();
  const largeClosed = once(large, 'close');
  large.send(JSON.stringify({id: 2, method: 'script.evaluate', params: {
    expression: "'x'.repeat(9 * 1024 * 1024)", target: {context: 'main'}, awaitPromise: false,
  }}));
  await within(largeClosed, 15000);
  console.log('PASS: oversized response closes connection');

  const busy = await connect();
  const busyClosed = once(busy, 'close');
  for (let id = 10; id < 19; id++) {
    busy.send(JSON.stringify({id, method: 'script.evaluate', params: {
      expression: 'new Promise(() => {})', target: {context: 'main'}, awaitPromise: true,
    }}));
  }
  await within(busyClosed);
  console.log('PASS: in-flight request limit');
} finally {
  for (const socket of sockets) {
    if (socket instanceof WebSocket) { socket.on('error', () => {}); socket.terminate(); }
    else socket.destroy();
  }
  if (server.exitCode === null && server.signalCode === null) {
    const exited = once(server, 'exit');
    server.kill('SIGTERM');
    await within(exited);
  }
  // The server itself must remove its token directory on SIGTERM.
  if (tokenFile) {
    await assert.rejects(access(dirname(tokenFile)), {code: 'ENOENT'});
  }
}
