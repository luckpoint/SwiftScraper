import puppeteer from 'puppeteer-core';
import {bidiHeaders} from './bidi-auth.mjs';

const endpoint = process.env.SWIFTSCRAPER_BIDI_ENDPOINT ?? 'ws://127.0.0.1:9222/session';
const query = process.env.GOOGLE_QUERY ?? 'Apple Swift';

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
    headers: bidiHeaders(endpoint),
    protocol: 'webDriverBiDi',
  });

  try {
    const pages = await browser.pages();
    const page = pages[0] ?? await browser.newPage();

    await page.evaluate(() => {
      location.href = 'https://www.google.com/';
      return true;
    });

    await waitForValue(page, () => {
      const candidates = [...document.querySelectorAll('button, input[type="submit"]')];
      const consentButton = candidates.find(element => {
        const text = `${element.innerText ?? ''} ${element.value ?? ''} ${element.ariaLabel ?? ''}`;
        return /accept all|i agree|agree|同意|すべて同意/i.test(text);
      });
      if (consentButton) {
        consentButton.click();
      }

      return document.querySelector('textarea[name="q"], input[name="q"]') ? true : false;
    }, { label: 'Google search input' });

    await page.evaluate(searchQuery => {
      const input = document.querySelector('textarea[name="q"], input[name="q"]');
      if (!input) {
        throw new Error('Google search input was not found');
      }

      input.focus();
      input.value = searchQuery;
      input.dispatchEvent(new InputEvent('input', {
        bubbles: true,
        data: searchQuery,
        inputType: 'insertText',
      }));
      input.dispatchEvent(new Event('change', { bubbles: true }));

      const buttons = [...document.querySelectorAll('input[name="btnK"], button[name="btnK"]')];
      const searchButton = buttons.find(element => !element.disabled);
      if (searchButton) {
        searchButton.click();
        return true;
      }

      const form = input.closest('form');
      if (form?.requestSubmit) {
        form.requestSubmit();
        return true;
      }

      if (form) {
        form.submit();
        return true;
      }

      throw new Error('Google search button/form was not found');
    }, query);

    await waitForValue(page, () => {
      return location.href.includes('/search') || document.querySelector('#search') ? true : false;
    }, { timeout: 5_000, label: 'Google search navigation' }).catch(async () => {
      await page.evaluate(searchQuery => {
        location.href = `https://www.google.com/search?q=${encodeURIComponent(searchQuery)}`;
        return true;
      }, query);
    });

    const resultState = await waitForValue(page, () => {
      if (location.hostname.endsWith('google.com') && location.pathname.startsWith('/sorry')) {
        return {
          blocked: true,
          body: document.body?.innerText?.slice(0, 800) ?? '',
          url: location.href,
        };
      }

      const rows = [];
      const seen = new Set();

      for (const link of document.querySelectorAll('#search a, a')) {
        const titleNode = link.querySelector('h3');
        const title = titleNode?.innerText?.trim();
        const href = link.href;

        if (!title || !href || seen.has(href)) {
          continue;
        }

        seen.add(href);

        const container = link.closest('div');
        const snippet = container?.innerText
          ?.split('\n')
          .map(line => line.trim())
          .filter(Boolean)
          .filter(line => line !== title)
          .join(' ');

        rows.push({ title, url: href, snippet });
      }

      return rows.length > 0 ? { results: rows.slice(0, 10) } : false;
    }, { label: 'Google search results' }).catch(async error => {
      await dumpPageState(page, 'Current page after failed result extraction');
      throw error;
    });

    if (resultState.blocked) {
      throw new Error(
        `Google returned a bot-detection page instead of search results: ${resultState.url}\n` +
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
  console.error('Puppeteer probe failed.');
  if (error?.stack) {
    console.error(error.stack);
  } else {
    console.error('Unknown connection or protocol error (details omitted to protect credentials).');
  }
  process.exitCode = 1;
});
