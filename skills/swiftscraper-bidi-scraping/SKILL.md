---
name: swiftscraper-bidi-scraping
description: Use this skill whenever the user wants another AI agent, automation script, Puppeteer client, or raw WebSocket client to control SwiftScraper through its WebDriver BiDi-style bridge. This skill covers starting the SwiftScraper BiDi server, connecting to it, navigating pages, waiting for dynamic content, using the `swiftScraper:scrape.*` extension APIs, extracting HTML/text/Markdown, handling cookies, taking screenshots, and diagnosing common connection or scraping failures.
---

# SwiftScraper BiDi Scraping

Use SwiftScraper as a WKWebView-based scraping browser exposed over WebSocket JSON. Treat it as a practical scraping bridge, not as a full Chrome/Firefox WebDriver BiDi implementation.

## When To Use

Use this skill when the task involves:

- Controlling SwiftScraper from another AI, script, or tool.
- Connecting Puppeteer with `protocol: "webDriverBiDi"`.
- Calling raw BiDi JSON commands over `ws://127.0.0.1:9222/session`.
- Waiting for SPA or dynamic content before extraction.
- Using `swiftScraper:scrape.extract`, `waitForSelector`, `autoScroll`, cookies, screenshots, or JavaScript evaluation.

For a one-shot task that downloads PDFs from a rendered link-list page, use the `swiftscraper-pdf-download` skill and prefer the CLI mode instead of the BiDi server:

```bash
swift run swift-scraper -- \
  https://example.com/legal/trust/ \
  --download-pdfs downloads \
  --auto-scroll
```

This saves files under `downloads/<host>/<source-path>/` and names each file as `<link text up to 30 chars>-<original filename>`. BiDi server mode still does not implement browser download control.

## Start The Server

From the SwiftScraper repository root:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-host 127.0.0.1 \
  --bidi-port 9222 \
  --visibility hidden-window \
  --verbose
```

The default endpoint is:

```text
ws://127.0.0.1:9222/session
```

Use `--visibility visible-window` when visual debugging is useful. Add `--url <url>` if the server should open an initial page before accepting client commands.

Avoid binding to public interfaces unless authentication and network restrictions are handled outside SwiftScraper.

## Smoke Test

Run this before deeper debugging:

```bash
npm install
npm run puppeteer:bidi-p1
```

Expected success output includes:

```text
SwiftScraper scraping extension commands passed.
P0/P1 BiDi smoke test passed.
```

For a non-default port:

```bash
SWIFTSCRAPER_BIDI_ENDPOINT=ws://127.0.0.1:9334/session npm run puppeteer:bidi-p1
```

## Connect From Puppeteer

```js
import puppeteer from 'puppeteer-core';

const browser = await puppeteer.connect({
  browserWSEndpoint: process.env.SWIFTSCRAPER_BIDI_ENDPOINT ?? 'ws://127.0.0.1:9222/session',
  protocol: 'webDriverBiDi',
});

const [page] = await browser.pages();
await page.goto('https://example.com', {waitUntil: 'domcontentloaded'});
const title = await page.evaluate(() => document.title);
await browser.disconnect();
```

Puppeteer high-level APIs are only partially compatible. Prefer raw `swiftScraper:scrape.*` commands for SwiftScraper-specific scraping workflows.

## Raw BiDi Command Shape

Send text WebSocket messages as JSON:

```json
{
  "id": 1,
  "method": "browsingContext.navigate",
  "params": {
    "context": "main",
    "url": "https://example.com",
    "wait": "interactive"
  }
}
```

Success response:

```json
{
  "id": 1,
  "type": "success",
  "result": {}
}
```

Error response:

```json
{
  "id": 1,
  "type": "error",
  "error": "invalid argument",
  "message": "..."
}
```

Use `context: "main"` unless a command explicitly allows no context. Current SwiftScraper BiDi server exposes a single browsing context and a single realm, both named `main`.

## Recommended Scraping Flow

1. Start the BiDi server.
2. Navigate with `browsingContext.navigate` or Puppeteer `page.goto`.
3. Wait for page readiness with `swiftScraper:scrape.waitForSelector`, `waitForText`, or `waitForFunction`.
4. For infinite/lazy content, call `swiftScraper:scrape.autoScroll`.
5. For SPAs, call `swiftScraper:scrape.waitForDOMStable`.
6. Extract with `swiftScraper:scrape.extract`.
7. Use `browsingContext.captureScreenshot` when visual proof or debugging is needed.

Example:

```json
{
  "id": 10,
  "method": "swiftScraper:scrape.waitForSelector",
  "params": {
    "context": "main",
    "selector": "article",
    "timeout": 10000,
    "polling": 250
  }
}
```

Then:

```json
{
  "id": 11,
  "method": "swiftScraper:scrape.extract",
  "params": {
    "context": "main",
    "mode": "contentOnly",
    "format": "markdown",
    "extractImages": true,
    "imageFilter": "article-only"
  }
}
```

## SwiftScraper Extension APIs

Use canonical `swiftScraper:scrape.*` names. Short `scrape.*` names exist as aliases for compatibility.

| Method | Purpose |
| --- | --- |
| `swiftScraper:scrape.getHTML` | Return `document.documentElement.outerHTML`. |
| `swiftScraper:scrape.getText` | Return `document.body.innerText`. |
| `swiftScraper:scrape.waitForSelector` | Poll until a CSS selector exists. |
| `swiftScraper:scrape.waitForText` | Poll until document text contains a string. |
| `swiftScraper:scrape.waitForFunction` | Poll until a JavaScript expression is truthy. |
| `swiftScraper:scrape.waitForDOMStable` | Wait until the DOM snapshot stops changing for a stable interval. |
| `swiftScraper:scrape.autoScroll` | Scroll by viewport until the page bottom and scroll height stabilize. |
| `swiftScraper:scrape.extract` | Run SwiftScraper's extraction engine in server mode. |
| `swiftScraper:scrape.getCookies` | Alias for runtime cookie retrieval. |
| `swiftScraper:scrape.setCookie` | Alias for runtime cookie creation/update. |
| `swiftScraper:scrape.deleteCookies` | Alias for runtime cookie deletion. |

Timing parameters are milliseconds:

- `timeout`: total wait budget, for example `10000`.
- `polling` or `pollInterval`: polling interval, for example `250`.
- `stableTime`: DOM stability duration for `waitForDOMStable`, for example `500`.

## Extract Options

`swiftScraper:scrape.extract` accepts:

| Param | Values |
| --- | --- |
| `mode` | `outerHTML`, `bodyText`, `selectorInnerHTML`, `contentOnly`, `structureInspection` |
| `selector` | Required when `mode` is `selectorInnerHTML`. |
| `format` | `plain` or `markdown`. |
| `prettyPrint` | Boolean, only affects plain HTML output. |
| `extractImages` | Boolean, enables SwiftScraper image heuristic filtering. |
| `imageFilter` | `all` or `article-only`. |
| `imageScoreThreshold` | Number from `0` to `1`. |
| `imageIncludeMaybe` | Boolean. |
| `imageDebug` | Boolean; returns debug JSON in `imageDebug`. |

Typical result:

```json
{
  "mode": "contentOnly",
  "format": "markdown",
  "data": "# Article title\n\nArticle body..."
}
```

## Standard BiDi Subset

Commonly useful supported commands:

- `session.status`
- `session.new`
- `session.subscribe`
- `session.unsubscribe`
- `browser.getUserContexts`
- `browser.close` as compatibility no-op
- `browsingContext.getTree`
- `browsingContext.navigate`
- `browsingContext.reload`
- `browsingContext.captureScreenshot`
- `browsingContext.setViewport`
- `script.evaluate`
- `script.callFunction`
- `script.addPreloadScript`
- `script.removePreloadScript`
- `storage.getCookies`
- `storage.setCookie`
- `storage.deleteCookies`
- `emulation.setScreenOrientationOverride` as compatibility no-op

Navigation `wait` supports `none`, `interactive`, and `complete`.

## Cookies

Set a cookie:

```json
{
  "id": 20,
  "method": "storage.setCookie",
  "params": {
    "cookie": {
      "name": "sid",
      "value": "abc",
      "domain": "example.com",
      "path": "/",
      "secure": true,
      "httpOnly": true
    }
  }
}
```

Read cookies:

```json
{
  "id": 21,
  "method": "storage.getCookies",
  "params": {}
}
```

Delete by filter:

```json
{
  "id": 22,
  "method": "storage.deleteCookies",
  "params": {
    "filter": {
      "name": "sid",
      "domain": "example.com",
      "path": "/"
    }
  }
}
```

## Troubleshooting

Connection refused:

- Confirm the server is running.
- Confirm the endpoint and port match.
- Check listeners with `lsof -nP -iTCP:9222 -sTCP:LISTEN`.

`unknown command`:

- Confirm the binary includes the BiDi scraping extension implementation.
- Use canonical `swiftScraper:scrape.*` method names.

Navigation timeout:

- Try `wait: "interactive"` instead of `complete`.
- Confirm the target URL is reachable from WKWebView.
- Use `--visibility visible-window` to inspect what WKWebView sees.

No extracted content:

- Add `waitForSelector` or `waitForFunction` before extraction.
- Run `autoScroll` for lazy-loaded pages.
- Try `mode: "outerHTML"` first, then narrow to `contentOnly` or `selectorInnerHTML`.

Bot detection:

- Treat bot-detection pages as target-site behavior, not BiDi connection failure.
- Do not bypass access controls or bot protections.

## Constraints

- macOS and WKWebView based.
- One browsing context: `main`.
- One realm: `main`.
- Not a WebDriver BiDi conformance target.
- No full network interception or HTTP response body capture.
- `WKURLSchemeHandler` does not provide general direct capture of normal `http` / `https` response bodies.
- Iframes, multiple contexts, permissions, advanced input actions, and full browser profile management are limited or unsupported.

## Policy

Users are responsible for complying with target site terms of service, robots policy, rate limits, and applicable laws. Keep the BiDi server bound to `127.0.0.1` unless the deployment explicitly protects it.
