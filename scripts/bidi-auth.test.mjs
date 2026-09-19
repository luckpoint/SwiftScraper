import assert from 'node:assert/strict';
import {test} from 'node:test';
import {chmodSync, mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {bidiHeaders, discoverTokenFile} from './bidi-auth.mjs';

test('local token discovery is endpoint-specific and fails closed', t => {
  const root = mkdtempSync(join(tmpdir(), 'bidi-auth-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const endpoint = 'ws://127.0.0.1:9222/session';
  function fixture(overrides = {}) {
    const folder = join(root, `swiftscraper-bidi-${randomUUID()}`);
    mkdirSync(folder, {mode: 0o700});
    writeFileSync(join(folder, 'server.json'), JSON.stringify({
      host: '127.0.0.1', port: 9222, pid: process.pid, ...overrides,
    }), {mode: 0o600});
    writeFileSync(join(folder, 'token'), 'a'.repeat(64), {mode: 0o600});
    return join(folder, 'token');
  }
  assert.throws(() => discoverTokenFile(endpoint, root), /No matching/);
  fixture({pid: -1});
  fixture({port: 9333});
  fixture({host: '::1'});
  assert.throws(() => discoverTokenFile(endpoint, root), /No matching/);
  const token = fixture();
  assert.equal(discoverTokenFile(endpoint, root), token);
  assert.equal(discoverTokenFile('ws://localhost:9222/session', root), token);
  for (const url of ['ws://example.com:9222/session', 'ws://127.0.0.1:9222/other',
    'ws://127.0.0.1:9222/session?x=1', 'wss://127.0.0.1:9222/session']) {
    assert.throws(() => discoverTokenFile(url, root), /requires a local/);
  }
  chmodSync(token, 0o644);
  assert.throws(() => discoverTokenFile(endpoint, root), /No matching/);
  chmodSync(token, 0o600);
  const duplicate = fixture();
  assert.throws(() => discoverTokenFile(endpoint, root), /Multiple matching/);
  rmSync(duplicate);
  symlinkSync(token, duplicate);
  assert.equal(discoverTokenFile(endpoint, root), token);

  const previous = process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE;
  t.after(() => {
    if (previous === undefined) delete process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE;
    else process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE = previous;
  });
  process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE = token;
  assert.deepEqual(bidiHeaders(endpoint), {Authorization: `Bearer ${'a'.repeat(64)}`});
  process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE = join(root, 'missing');
  assert.throws(() => bidiHeaders(endpoint)); // Explicit paths never silently fall back.
  process.env.SWIFTSCRAPER_BIDI_TOKEN_FILE = token;
  writeFileSync(token, 'invalid');
  assert.throws(() => bidiHeaders(endpoint), /Invalid BiDi token/);
});
