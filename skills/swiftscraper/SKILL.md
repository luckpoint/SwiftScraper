---
name: swiftscraper
description: Use when working on the SwiftScraper repository in this workspace, a macOS WKWebView Swift CLI and WebDriver BiDi scraping bridge. Covers its CLI scraping, rendering waits, cookies and headers, sitemap and URL-file batch runs, Markdown and image extraction, linked PDF downloads, Markdown-to-PDF generation, BiDi server operation with Puppeteer or raw WebSocket clients, and edits to its Swift sources and tests. Do not use for general web-scraping questions, for Playwright, Puppeteer, or Selenium work unrelated to this repository, or for other scraping projects.
---

# SwiftScraper

Use this skill for SwiftScraper tasks in this repository: changing the tool, running it from the CLI, scraping rendered pages, downloading linked PDFs, operating the BiDi bridge, or explaining supported workflows.

## Quick Orientation

SwiftScraper is macOS-only and uses `WKWebView`. It is not a fully headless browser and not a complete WebDriver BiDi implementation.

From the repository root, prefer:

```bash
swift run swift-scraper -- https://example.com
```

Use `--` after `swift run swift-scraper` before passing SwiftScraper options.

Read these docs when a task needs more detail:

- `README.md`: CLI overview and examples
- `docs/01-page-loading.md`: page loading model
- `docs/02-cookie-injection.md`: cookies and cookie jar behavior
- `docs/03-rendering-wait.md`: wait options
- `docs/04-html-dom-extraction.md`: extraction modes
- `docs/08-batch-processing.md`: sitemap and URL-file batch
- `docs/09-image-extraction.md`: image heuristic
- `docs/10-pdf-generation.md`: Markdown-to-PDF generation
- `docs/11-webdriver-bidi-bridge.md`: BiDi bridge
- `docs/12-pdf-link-download.md`: linked PDF downloads

## Choose The Workflow

Use CLI scraping for one-shot rendered page extraction:

```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --output out/article.md
```

Use batch scraping when the user has a sitemap or URL list:

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --content-only \
  --markdown \
  --concurrency 4 \
  --output out/pages.json
```

```bash
swift run swift-scraper -- \
  --url-file urls.txt \
  --inspect-structure \
  --concurrency 3 \
  --output out/url-file-batch.json
```

Use PDF link download mode when the user wants linked PDFs saved from rendered pages:

```bash
swift run swift-scraper -- \
  https://example.com/legal/trust/ \
  --download-pdfs downloads \
  --auto-scroll
```

Use BiDi server mode when another agent, Puppeteer client, or raw WebSocket client must control SwiftScraper interactively:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-host 127.0.0.1 \
  --bidi-port 9222 \
  --visibility hidden-window \
  --verbose
```

## CLI Scraping

Default output is `document.documentElement.outerHTML`. Use the extraction mode that matches the task:

| Mode | Option |
| --- | --- |
| Full HTML | default |
| Body text | `--body-text` |
| Element HTML | `--selector-inner-html <css>` |
| Main content candidate | `--content-only` |
| Structure report | `--inspect-structure` |

Use `--markdown` only with HTML-producing modes. Use `--pretty-print` only for plain HTML; it conflicts with `--markdown`.

For dynamic pages, add the smallest needed wait:

```bash
swift run swift-scraper -- \
  https://example.com/app \
  --wait-selector "#app" \
  --wait-text "Loaded" \
  --auto-scroll \
  --dom-stable-delay 1.0 \
  --wait-timeout 20
```

For image filtering in article output:

```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --extract-images \
  --image-filter article-only \
  --image-debug
```

## Cookies And Headers

Inject a cookie directly:

```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --cookie 'name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true'
```

Load cookies from JSON with `--cookie-file <path>`. Use `--cookie-jar <path>` to load existing cookies before a single-page run and save WebKit CookieStore cookies after the run.

Do not use `--cookie-jar` with `--sitemap` or `--url-file`; batch rejects it.

Use `--header 'Name: Value'` for request headers. For PDF download requests, explicit `User-Agent` and `Cookie` headers take precedence over automatic propagation.

## PDF Link Downloads

Use `--download-pdfs <dir>` for PDF-only output. It writes the PDF result JSON to stdout.

```bash
swift run swift-scraper -- \
  https://www.okta.com/legal/trustandcompliance/ \
  --download-pdfs downloads \
  --auto-scroll
```

Use it with batch inputs when scraping multiple pages for PDFs:

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --download-pdfs downloads \
  --concurrency 4
```

Use `--download-linked-pdfs <dir>` when the user wants normal scrape output and linked PDFs as a sidecar:

```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/docs.md
```

PDF files are saved under:

```text
<download-root>/<source-host>/<source-path>/
```

Filenames use:

```text
<link text up to 30 chars>-<original filename>
```

If link text is empty, use only the original filename. Unsafe filename characters are replaced with `_`; duplicates receive `-2`, `-3`, and so on.

PDF link discovery happens in the rendered WKWebView DOM through `document.querySelectorAll('a[href]')`. The downloader keeps `http:`, `https:`, and `file:` links whose path ends with `.pdf`, after removing fragments and deduplicating URLs.

PDF bytes are downloaded with `URLSession`. SwiftScraper propagates the WKWebView `navigator.userAgent` unless an explicit `User-Agent` header was provided, and propagates matching cookies from `WKWebsiteDataStore.httpCookieStore` unless an explicit `Cookie` header was provided.

For a post-processing example that verifies downloaded PDFs and stages them into a sync folder, see `scripts/stage_verified_pdfs.py`.

Known limits:

- `.pdf` path links only; download endpoints that return PDFs without a `.pdf` path are future candidates, not implemented.
- Response `Content-Type` is not validated.
- BiDi server mode does not implement browser download control.

## Markdown To PDF

Use `--pdf <file.md>` for Markdown-to-PDF conversion:

```bash
swift run swift-scraper -- \
  --pdf README.md \
  --output out/readme.pdf
```

This is separate from PDF link downloads. Do not combine `--pdf` with `--download-pdfs`, `--download-linked-pdfs`, normal extraction output options, or BiDi server mode.

## BiDi Bridge

Start the server for external clients:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-port 9222 \
  --visibility hidden-window \
  --verbose
```

Default endpoint:

```text
ws://127.0.0.1:9222/session
```

Use `--url <url>` to load an initial page before accepting commands. `--bidi-host` accepts only `127.0.0.1`, `::1`, or `localhost`; any other host is rejected at bind time. Use an SSH tunnel for remote access and transfer the token securely.

For smoke testing:

```bash
npm run puppeteer:bidi-p1
```

Every connection requires `Authorization: Bearer <token>`. The server mints a fresh
token per run and prints a `BiDi token file:` path, never the secret. Clients read
that owner-only file; `scripts/bidi-auth.mjs` discovers it automatically for a local
`/session` endpoint.

For Puppeteer:

```js
import puppeteer from 'puppeteer-core';
import {bidiHeaders} from './scripts/bidi-auth.mjs';

const endpoint = process.env.SWIFTSCRAPER_BIDI_ENDPOINT ?? 'ws://127.0.0.1:9222/session';

const browser = await puppeteer.connect({
  browserWSEndpoint: endpoint,
  headers: bidiHeaders(endpoint),
  protocol: 'webDriverBiDi',
});
```

For a raw WebSocket client, pass the same headers:

```js
const webSocket = new WebSocket(endpoint, {headers: bidiHeaders(endpoint)});
```

Set `SWIFTSCRAPER_BIDI_TOKEN_FILE` explicitly when discovery cannot pick a single
match: a remote endpoint, a non-default temp directory, or several servers running
at once. See `docs/11-webdriver-bidi-bridge.md` for the access-control model.

Prefer canonical SwiftScraper extension commands:

| Method | Purpose |
| --- | --- |
| `swiftScraper:scrape.getHTML` | Return full HTML |
| `swiftScraper:scrape.getText` | Return body text |
| `swiftScraper:scrape.waitForSelector` | Wait for CSS selector |
| `swiftScraper:scrape.waitForText` | Wait for text |
| `swiftScraper:scrape.waitForFunction` | Wait for JS expression |
| `swiftScraper:scrape.waitForDOMStable` | Wait for DOM stability |
| `swiftScraper:scrape.autoScroll` | Scroll lazy pages |
| `swiftScraper:scrape.extract` | Run extraction engine |
| `swiftScraper:scrape.getCookies` | Read runtime cookies |
| `swiftScraper:scrape.setCookie` | Set runtime cookie |
| `swiftScraper:scrape.deleteCookies` | Delete runtime cookies |

`context` is normally `main`. Navigation `wait` supports `none`, `interactive`, and `complete`.

Do not use BiDi server mode with one-shot output options, batch options, `--pdf`, `--download-pdfs`, `--download-linked-pdfs`, or `--cookie-jar`.

## Development And Verification

When changing SwiftScraper behavior, inspect the existing implementation before editing:

- CLI parsing: `Sources/SwiftScraperCore/CLIParser.swift`
- Main scraping flow: `Sources/SwiftScraperCore/WebScraper.swift`
- Run launcher and batch flow: `Sources/SwiftScraperCore/ScraperLauncher.swift`
- PDF link downloading: `Sources/SwiftScraperCore/PDFDownloadLauncher.swift`
- BiDi server and dispatcher: files under `Sources/SwiftScraperCore/` with `BiDi` in the name
- Tests: `Tests/SwiftScraperCoreTests/`

Run focused tests for parser or PDF changes first, then full tests when practical:

```bash
swift test --filter CLIParserTests
swift test --filter PDFDownload
swift test
```

Use `git diff --check` before finishing.

## Troubleshooting

If CLI extraction misses content, add explicit wait conditions, try `--visibility visible-window`, and inspect `--verbose` logs.

If PDF downloads fail, confirm links end with `.pdf`, check `files[].error` or `pdf-downloads.json`, and verify cookies / User-Agent are present.

If BiDi connection fails, confirm the server is listening on the expected endpoint and that the client uses `ws://127.0.0.1:9222/session`.

If Puppeteer high-level APIs fail, prefer raw `swiftScraper:scrape.*` commands; the bridge is a scraping subset, not a browser conformance target.
