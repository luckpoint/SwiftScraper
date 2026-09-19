import http from 'node:http';
import {once} from 'node:events';
import {inspect} from 'node:util';
import puppeteer from 'puppeteer-core';
import WebSocket from 'ws';
import {bidiHeaders} from './bidi-auth.mjs';

const endpoint = process.env.SWIFTSCRAPER_BIDI_ENDPOINT ?? 'ws://127.0.0.1:9222/session';

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function normalizeText(text) {
  return String(text ?? '').replace(/\s+/g, ' ').trim();
}

function makeHTML({title, marker}) {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
  <script>
    window.__preloadSeenByPageScript = window.__swiftScraperP1Preload === 'installed';
    console.log('page-script:preload=' + window.__preloadSeenByPageScript);
    document.addEventListener('DOMContentLoaded', () => {
      document.body.dataset.domContentLoaded = 'true';
      const ready = document.createElement('p');
      ready.id = 'ready';
      ready.textContent = '${marker}';
      document.body.appendChild(ready);
      console.log('domcontentloaded:${marker}');
    }, { once: true });
  </script>
</head>
<body>
  <main>
    <h1>${title}</h1>
    <p id="marker">${marker}</p>
  </main>
</body>
</html>`;
}

async function startFixtureServer() {
  const server = http.createServer((request, response) => {
    const path = new URL(request.url ?? '/', 'http://127.0.0.1').pathname;
    console.log(`fixture request: ${request.method} ${path}`);

    if (path === '/p1-smoke') {
      response.writeHead(200, {'content-type': 'text/html; charset=utf-8'});
      response.end(makeHTML({title: 'SwiftScraper BiDi P1 Smoke', marker: 'ready'}));
      return;
    }

    if (path === '/after-remove') {
      response.writeHead(200, {'content-type': 'text/html; charset=utf-8'});
      response.end(makeHTML({title: 'SwiftScraper BiDi P1 After Remove', marker: 'removed'}));
      return;
    }

    response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
    response.end('not found');
  });

  server.listen(0, '127.0.0.1');
  await once(server, 'listening');

  const address = server.address();
  assert(address && typeof address === 'object', 'Fixture server did not return a TCP address');

  return {
    baseURL: `http://127.0.0.1:${address.port}`,
    close: () => new Promise((resolve, reject) => {
      server.close(error => {
        if (error) {
          reject(error);
        } else {
          resolve();
        }
      });
    }),
  };
}

async function waitForValue(page, pageFunction, {
  timeout = 10_000,
  interval = 100,
  label = 'condition',
} = {}) {
  const deadline = Date.now() + timeout;
  let lastError;

  while (Date.now() < deadline) {
    try {
      const value = await page.evaluate(pageFunction);
      if (value) {
        return value;
      }
    } catch (error) {
      lastError = error;
    }

    await new Promise(resolve => setTimeout(resolve, interval));
  }

  const suffix = lastError ? ` Last error: ${lastError.message ?? lastError}` : '';
  throw new Error(`Timed out waiting for ${label}.${suffix}`);
}

function assertPngBase64(data) {
  assert(typeof data === 'string' && data.length > 0, 'Screenshot did not return base64 data');

  const signature = Buffer.from(data, 'base64').subarray(0, 8);
  assert(
    signature.equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
    'Screenshot data is not a PNG'
  );
}

function waitForWebSocket(webSocket, type) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      webSocket.removeEventListener(type, handleEvent);
      webSocket.removeEventListener('error', handleError);
    };
    const handleEvent = event => {
      cleanup();
      resolve(event);
    };
    const handleError = event => {
      cleanup();
      reject(new Error(`WebSocket ${type} wait failed`));
    };

    webSocket.addEventListener(type, handleEvent, {once: true});
    webSocket.addEventListener('error', handleError, {once: true});
  });
}

async function openRawBiDiConnection(url) {
  const webSocket = new WebSocket(url, {headers: bidiHeaders(url)});
  const pending = new Map();
  let nextId = 1;

  webSocket.addEventListener('message', event => {
    const message = JSON.parse(String(event.data));
    if (!Object.hasOwn(message, 'id')) {
      return;
    }

    const callbacks = pending.get(message.id);
    if (!callbacks) {
      return;
    }

    pending.delete(message.id);
    if (message.type === 'success') {
      callbacks.resolve(message.result ?? {});
    } else {
      callbacks.reject(new Error(`${message.error ?? 'error'}: ${message.message ?? ''}`));
    }
  });

  await waitForWebSocket(webSocket, 'open');

  return {
    send(method, params = {}) {
      const id = nextId++;
      const payload = JSON.stringify({id, method, params});
      return new Promise((resolve, reject) => {
        pending.set(id, {resolve, reject});
        webSocket.send(payload);
      });
    },
    close() {
      if (webSocket.readyState === WebSocket.OPEN || webSocket.readyState === WebSocket.CONNECTING) {
        webSocket.close();
      }
    },
  };
}

async function main() {
  const fixture = await startFixtureServer();
  console.log(`Fixture server: ${fixture.baseURL}`);
  console.log(`Connecting Puppeteer to ${endpoint}`);

  const browser = await puppeteer.connect({
    browserWSEndpoint: endpoint,
    headers: bidiHeaders(endpoint),
    protocol: 'webDriverBiDi',
  });

  const consoleMessages = [];
  let rawBiDi;

  try {
    const pages = await browser.pages();
    const page = pages[0] ?? await browser.newPage();
    rawBiDi = await openRawBiDiConnection(endpoint);

    page.on('console', message => {
      const text = message.text();
      consoleMessages.push(text);
      console.log(`console: ${text}`);
    });

    await page.setViewport({width: 900, height: 500});

    const preload = await page.evaluateOnNewDocument(() => {
      window.__swiftScraperP1Preload = 'installed';
      console.log('preload:installed');
    });

    await page.goto(`${fixture.baseURL}/p1-smoke`, {
      waitUntil: 'domcontentloaded',
      timeout: 15_000,
    });

    const firstState = await waitForValue(page, () => {
      if (document.body?.dataset.domContentLoaded !== 'true') {
        return false;
      }

      return {
        domContentLoaded: document.body.dataset.domContentLoaded,
        marker: document.querySelector('#ready')?.textContent ?? '',
        preloadSeenByPageScript: window.__preloadSeenByPageScript === true,
        preloadValue: window.__swiftScraperP1Preload,
        title: document.title,
        viewport: {
          width: window.innerWidth,
          height: window.innerHeight,
        },
      };
    }, {label: 'first fixture state'});

    assert(firstState.preloadValue === 'installed', 'Preload script did not install its marker');
    assert(firstState.preloadSeenByPageScript, 'Page script did not see preload marker at document start');
    assert(firstState.marker === 'ready', `Unexpected ready marker: ${firstState.marker}`);
    assert(firstState.viewport.width === 900, `Unexpected viewport width: ${firstState.viewport.width}`);
    assert(firstState.viewport.height === 500, `Unexpected viewport height: ${firstState.viewport.height}`);

    const waitSelector = await rawBiDi.send('swiftScraper:scrape.waitForSelector', {
      context: 'main',
      selector: '#ready',
      timeout: 5_000,
      polling: 100,
    });
    assert(waitSelector.matched === true, `waitForSelector did not match: ${inspect(waitSelector)}`);

    const waitText = await rawBiDi.send('swiftScraper:scrape.waitForText', {
      context: 'main',
      text: 'ready',
      timeout: 5_000,
      polling: 100,
    });
    assert(waitText.matched === true, `waitForText did not match: ${inspect(waitText)}`);

    const waitFunction = await rawBiDi.send('swiftScraper:scrape.waitForFunction', {
      context: 'main',
      expression: "document.querySelector('#ready')?.textContent === 'ready'",
      timeout: 5_000,
      polling: 100,
    });
    assert(waitFunction.matched === true, `waitForFunction did not match: ${inspect(waitFunction)}`);

    const domStable = await rawBiDi.send('swiftScraper:scrape.waitForDOMStable', {
      context: 'main',
      stableTime: 200,
      timeout: 5_000,
      polling: 100,
    });
    assert(domStable.matched === true, `waitForDOMStable did not match: ${inspect(domStable)}`);

    const autoScroll = await rawBiDi.send('swiftScraper:scrape.autoScroll', {
      context: 'main',
      timeout: 5_000,
      polling: 100,
    });
    assert(autoScroll.reachedBottom === true, `autoScroll did not reach bottom: ${inspect(autoScroll)}`);

    const extractedMarkdown = await rawBiDi.send('swiftScraper:scrape.extract', {
      context: 'main',
      mode: 'contentOnly',
      format: 'markdown',
    });
    assert(
      normalizeText(extractedMarkdown.data).includes('SwiftScraper BiDi P1 Smoke'),
      `scrape.extract markdown missed title: ${inspect(extractedMarkdown)}`
    );

    const extractedMain = await rawBiDi.send('scrape.extract', {
      context: 'main',
      mode: 'selectorInnerHTML',
      selector: 'main',
    });
    assert(
      extractedMain.data.includes('ready'),
      `scrape.extract alias missed ready marker: ${inspect(extractedMain)}`
    );
    console.log('SwiftScraper scraping extension commands passed.');

    const screenshot = await page.screenshot({
      encoding: 'base64',
      type: 'png',
    });
    assertPngBase64(screenshot);

    await page.setCookie({
      name: 'swift_scraper_p1',
      value: 'cookie-value',
      url: fixture.baseURL,
      path: '/',
    });

    const cookies = await page.cookies(fixture.baseURL);
    const cookie = cookies.find(cookie => cookie.name === 'swift_scraper_p1');
    assert(cookie?.value === 'cookie-value', `Runtime cookie was not round-tripped: ${inspect(cookies)}`);

    await page.deleteCookie({
      name: 'swift_scraper_p1',
      url: fixture.baseURL,
      path: '/',
    });

    const cookiesAfterDelete = await page.cookies(fixture.baseURL);
    assert(
      !cookiesAfterDelete.some(cookie => cookie.name === 'swift_scraper_p1'),
      `Runtime cookie was not deleted: ${inspect(cookiesAfterDelete)}`
    );

    let javascriptError;
    try {
      await page.evaluate(() => swiftScraperP1MissingSymbol.value);
    } catch (error) {
      javascriptError = error;
    }

    assert(javascriptError, 'JavaScript error probe unexpectedly succeeded');
    assert(
      /ReferenceError|swiftScraperP1MissingSymbol|javascript error/i.test(javascriptError.message ?? ''),
      `Unexpected JavaScript error message: ${javascriptError.message ?? javascriptError}`
    );

    await page.removeScriptToEvaluateOnNewDocument(preload.identifier);
    await page.goto(`${fixture.baseURL}/after-remove`, {
      waitUntil: 'domcontentloaded',
      timeout: 15_000,
    });

    const secondState = await waitForValue(page, () => {
      if (document.body?.dataset.domContentLoaded !== 'true') {
        return false;
      }

      return {
        marker: document.querySelector('#ready')?.textContent ?? '',
        preloadSeenByPageScript: window.__preloadSeenByPageScript === true,
        preloadValue: window.__swiftScraperP1Preload,
      };
    }, {label: 'second fixture state'});

    assert(secondState.marker === 'removed', `Unexpected second marker: ${secondState.marker}`);
    assert(!secondState.preloadSeenByPageScript, 'Preload marker was still visible after removal');
    assert(secondState.preloadValue === undefined, 'Preload value still exists after removal');

    assert(
      consoleMessages.some(message => message.includes('preload:installed')),
      `Preload console event was not observed. Messages: ${inspect(consoleMessages)}`
    );
    assert(
      consoleMessages.some(message => message.includes('domcontentloaded:ready')),
      `DOMContentLoaded console event was not observed. Messages: ${inspect(consoleMessages)}`
    );

    console.log('P0/P1 BiDi smoke test passed.');
    console.log(`First page: ${normalizeText(firstState.title)} ${inspect(firstState.viewport)}`);
    console.log(`Screenshot bytes: ${Buffer.from(screenshot, 'base64').byteLength}`);
  } finally {
    rawBiDi?.close();
    await browser.disconnect();
    await fixture.close();
  }
}

main().catch(error => {
  console.error('Puppeteer BiDi P1 smoke test failed.');
  if (error?.stack) {
    console.error(error.stack);
  } else {
    console.error('Unknown connection or protocol error (details omitted to protect credentials).');
  }
  process.exitCode = 1;
});
