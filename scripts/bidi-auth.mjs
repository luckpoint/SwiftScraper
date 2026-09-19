import {lstatSync, readdirSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const guidance = 'Set SWIFTSCRAPER_BIDI_TOKEN_FILE to the token file printed by the server';

function privateEntry(path, directory = false) {
  const stat = lstatSync(path);
  return (directory ? stat.isDirectory() : stat.isFile())
    && stat.uid === process.getuid() && (stat.mode & 0o077) === 0;
}

function liveProcess(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch { return false; }
}

// Never discover credentials for a remote destination, or choose among ambiguous matches.
export function discoverTokenFile(endpoint, directory = tmpdir()) {
  const url = new URL(endpoint);
  const host = url.hostname === 'localhost' ? '127.0.0.1' : url.hostname.replace(/^\[|\]$/g, '');
  if (url.protocol !== 'ws:' || !['127.0.0.1', '::1'].includes(host)
      || url.pathname !== '/session' || url.search || url.hash || url.username || url.password) {
    throw new Error(`Automatic BiDi authentication requires a local /session endpoint. ${guidance}`);
  }
  const candidates = [];
  for (const name of readdirSync(directory)) {
    if (!/^swiftscraper-bidi-[0-9a-f-]{36}$/i.test(name)) continue;
    const folder = join(directory, name);
    const metadata = join(folder, 'server.json');
    const token = join(folder, 'token');
    try {
      if (!privateEntry(folder, true) || !privateEntry(metadata) || !privateEntry(token)) continue;
      const server = JSON.parse(readFileSync(metadata, 'utf8'));
      if (server.host === host && server.port === Number(url.port || 80) && liveProcess(server.pid)) {
        candidates.push(token);
      }
    } catch { /* Stale, incomplete or inaccessible entries are not discovery candidates. */ }
  }
  if (candidates.length !== 1) {
    throw new Error(`${candidates.length ? 'Multiple matching' : 'No matching'} local BiDi servers found. ${guidance}`);
  }
  return candidates[0];
}

export function bidiHeaders(endpoint = process.env.SWIFTSCRAPER_BIDI_ENDPOINT ?? 'ws://127.0.0.1:9222/session') {
  const path = process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE || discoverTokenFile(endpoint);
  const token = readFileSync(path, 'utf8').trim();
  if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid BiDi token file');
  return {Authorization: `Bearer ${token}`};
}
