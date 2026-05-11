import puppeteer from 'puppeteer-core';
import { inspect } from 'node:util';

const endpoint = process.env.SWIFTSCRAPER_BIDI_ENDPOINT ?? 'ws://127.0.0.1:9222/session';
const query = process.env.YAHOO_QUERY ?? 'Apple Swift';

function normalizeText(text) {
  return text.replace(/\s+/g, ' ').trim();
}

function printResult(result, index) {
  console.log(`${index + 1}. ${result.title}`);
  if (result.url) {
    console.log(`   ${result.url}`);
  }
  if (result.snippet) {
    console.log(`   ${result.snippet}`);
  }
}

async function dumpPageState(page, label) {
  const state = await page.evaluate(() => ({
    body: document.body?.innerText?.slice(0, 1200) ?? '',
    title: document.title,
    url: location.href,
  })).catch(error => ({
    body: `Unable to read page body: ${error.message ?? error}`,
    title: '',
    url: '',
  }));

  console.error(`${label}: ${state.title} ${state.url}`);
  console.error(normalizeText(state.body));
}

async function waitForValue(page, pageFunction, {
  timeout = 30_000,
  interval = 500,
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

async function main() {
  console.log(`Connecting Puppeteer to ${endpoint}`);

  const browser = await puppeteer.connect({
    browserWSEndpoint: endpoint,
    protocol: 'webDriverBiDi',
  });

  try {
    const pages = await browser.pages();
    const page = pages[0] ?? await browser.newPage();

    await page.evaluate(() => {
      location.href = 'https://www.yahoo.co.jp/';
      return true;
    });

    await waitForValue(page, () => {
      return document.querySelector(
        'input[name="p"], input[name="query"], input[type="search"], input[aria-label*="検索"], input[placeholder*="検索"]'
      ) ? true : false;
    }, { label: 'Yahoo search input' });

    await page.evaluate(searchQuery => {
      const input = document.querySelector(
        'input[name="p"], input[name="query"], input[type="search"], input[aria-label*="検索"], input[placeholder*="検索"]'
      );
      if (!input) {
        throw new Error('Yahoo search input was not found');
      }

      input.focus();
      input.value = searchQuery;
      input.dispatchEvent(new InputEvent('input', {
        bubbles: true,
        data: searchQuery,
        inputType: 'insertText',
      }));
      input.dispatchEvent(new Event('change', { bubbles: true }));

      const form = input.closest('form');
      const searchButton = form?.querySelector(
        'button[type="submit"], input[type="submit"], button[aria-label*="検索"]'
      ) ?? document.querySelector(
        'button[type="submit"], input[type="submit"], button[aria-label*="検索"]'
      );

      if (searchButton && !searchButton.disabled) {
        searchButton.click();
        return true;
      }

      if (form?.requestSubmit) {
        form.requestSubmit();
        return true;
      }

      if (form) {
        form.submit();
        return true;
      }

      throw new Error('Yahoo search button/form was not found');
    }, query);

    await waitForValue(page, () => {
      return location.hostname === 'search.yahoo.co.jp' && location.pathname.includes('/search') ? true : false;
    }, { timeout: 5_000, label: 'Yahoo search navigation' }).catch(async () => {
      await page.evaluate(searchQuery => {
        location.href = `https://search.yahoo.co.jp/search?p=${encodeURIComponent(searchQuery)}&ei=UTF-8`;
        return true;
      }, query);
    });

    const resultState = await waitForValue(page, () => {
      const bodyText = document.body?.innerText ?? '';
      if (/不正なアクセス|通常と異なる|自動プログラム|ロボット|captcha|CAPTCHA/i.test(bodyText)) {
        return {
          blocked: true,
          body: bodyText.slice(0, 800),
          url: location.href,
        };
      }

      const rows = [];
      const seen = new Set();

      for (const link of document.querySelectorAll('#web a[href], main a[href], a[href]')) {
        const titleNode = link.querySelector('h3') ?? link.closest('h3');
        const title = titleNode?.innerText?.trim();
        const href = link.href;

        if (!title || title.length < 2 || !href.startsWith('http') || seen.has(href)) {
          continue;
        }

        if (href.includes('yahoo.co.jp') && /検索|画像|動画|知恵袋|ニュース|ショッピング|地図/.test(title)) {
          continue;
        }

        seen.add(href);

        const container = link.closest('section, article, li, div');
        const snippet = container?.innerText
          ?.split('\n')
          .map(line => line.trim())
          .filter(Boolean)
          .filter(line => line !== title)
          .slice(0, 5)
          .join(' ');

        rows.push({ title, url: href, snippet });
      }

      return rows.length > 0 ? { results: rows.slice(0, 10) } : false;
    }, { label: 'Yahoo search results' }).catch(async error => {
      await dumpPageState(page, 'Current page after failed result extraction');
      throw error;
    });

    if (resultState.blocked) {
      throw new Error(
        `Yahoo returned a bot-detection page instead of search results: ${resultState.url}\n` +
        normalizeText(resultState.body)
      );
    }

    const results = resultState.results;

    console.log(`Found ${results.length} result(s) for "${query}"`);
    results.map(result => ({
      title: normalizeText(result.title),
      url: result.url,
      snippet: normalizeText(result.snippet ?? ''),
    })).forEach(printResult);
  } finally {
    await browser.disconnect();
  }
}

main().catch(error => {
  console.error('Puppeteer Yahoo probe failed.');
  if (error?.stack) {
    console.error(error.stack);
  } else {
    console.error(inspect(error, { depth: 8, colors: false }));
  }
  process.exitCode = 1;
});
