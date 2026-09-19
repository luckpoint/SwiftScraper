import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {access, rm} from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import {basename, dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const binary = process.env.SWIFTSCRAPER_BINARY ?? resolve(root, '.build/debug/swift-scraper');
function within(promise, ms = 15000) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Signal test timed out')), ms);
  })]).finally(() => clearTimeout(timer));
}

for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  for (const duringStartup of [false, true]) {
    test(`${signal} cleans token directory ${duringStartup ? 'during navigation startup' : 'after listening'}`, async () => {
      const fixture = http.createServer(() => {}); // Deliberately never finish navigation.
      const reservation = net.createServer();
      let child;
      let exited;
      let tokenDirectory;
      try {
        fixture.listen(0, '127.0.0.1');
        await once(fixture, 'listening');
        reservation.listen(0, '127.0.0.1');
        await once(reservation, 'listening');
        const port = reservation.address().port;
        await new Promise(resolve => reservation.close(resolve));
        const args = ['--bidi-server', '--bidi-port', String(port)];
        if (duringStartup) args.push('--url', `http://127.0.0.1:${fixture.address().port}/`);
        const request = duringStartup ? once(fixture, 'request') : null;
        child = spawn(binary, args, {
          cwd: root, stdio: ['ignore', 'ignore', 'pipe'],
        });
        exited = once(child, 'exit');
        await within(new Promise((resolve, reject) => {
          let log = '';
          child.on('error', reject);
          child.on('exit', () => reject(new Error('Server exited before ready')));
          child.stderr.on('data', chunk => {
            log += chunk;
            const match = log.match(/BiDi token file: (.+)/);
            if (match) tokenDirectory = dirname(match[1].trim());
            if (tokenDirectory && (duringStartup || log.includes('BiDi server listening:'))) resolve();
          });
        }));
        if (request) await within(request);
        await access(tokenDirectory);
        child.kill(signal);
        assert.deepEqual(await within(exited), [code, null]);
        await assert.rejects(access(tokenDirectory), {code: 'ENOENT'});
      } finally {
        if (child && child.exitCode === null && child.signalCode === null) {
          child.kill('SIGKILL');
          await within(exited);
        }
        fixture.closeAllConnections();
        await new Promise(resolve => fixture.close(resolve));
        reservation.close();
        // On failure remove only the exact directory reported by this test's child.
        if (tokenDirectory && /^swiftscraper-bidi-[0-9a-f-]{36}$/i.test(basename(tokenDirectory))) {
          await rm(tokenDirectory, {recursive: true, force: true});
        }
      }
    });
  }
}
