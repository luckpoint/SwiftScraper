---
name: swiftscraper-pdf-download
description: Use this skill when the user wants SwiftScraper to download PDF files from rendered pages, including single PDF link-list pages, sitemap or URL-file batches, and normal scraping with linked PDF sidecar downloads. This skill covers `--download-pdfs`, `--download-linked-pdfs`, WKWebView DOM-based PDF link discovery, site/path-based output directories, link-text-derived filenames, User-Agent and Cookie propagation from WKWebView to URLSession, and troubleshooting PDF download failures.
---

# SwiftScraper PDF Download

Use this skill when SwiftScraper should save PDF files linked from rendered pages, such as legal, trust, compliance, documentation, or support pages.

This is a CLI workflow, not a WebDriver BiDi browser download workflow.

## Choose The Mode

Use `--download-pdfs <dir>` when the user wants PDF files only:

```bash
swift run swift-scraper -- \
  https://example.com/legal/trust/ \
  --download-pdfs downloads \
  --auto-scroll
```

Use `--download-pdfs <dir>` with batch inputs when the user wants PDF files from multiple pages and does not need normal scrape output:

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --download-pdfs downloads \
  --concurrency 4
```

```bash
swift run swift-scraper -- \
  --url-file urls.txt \
  --download-pdfs downloads \
  --concurrency 4
```

Use `--download-linked-pdfs <dir>` when the user wants normal scrape output and PDF files as a sidecar:

```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/docs.md
```

This also works with `--sitemap` and `--url-file`; the normal batch JSON remains stdout or `--output`, and the PDF manifest is written to `<dir>/pdf-downloads.json`.

## Rendering Helpers

Use the same rendering helpers as normal scraping when needed:

```bash
swift run swift-scraper -- \
  https://example.com/legal/trust/ \
  --download-pdfs downloads \
  --wait-selector ".reports" \
  --wait-text "SOC" \
  --auto-scroll \
  --header "Accept-Language: en-US,en;q=0.9"
```

For single-page runs, `--cookie-jar` may be used. For `--sitemap` and `--url-file` batch runs, `--cookie-jar` is rejected.

## How Links Are Found

SwiftScraper loads the page in WKWebView, applies cookies/headers, waits for rendering, then evaluates JavaScript against the rendered DOM.

The extraction script scans:

```js
document.querySelectorAll('a[href]')
```

It keeps links whose resolved URL uses `http:`, `https:`, or `file:` and whose path ends with `.pdf` case-insensitively. It deduplicates exact PDF URLs after removing fragments.

For `--download-linked-pdfs`, SwiftScraper does not load the page twice. It collects PDF links during the same WKWebView run used for normal scraping.

## Output Layout

Files are saved under:

```text
<output-root>/<source-host>/<source-path>/
```

Example:

```text
downloads/
  www.okta.com/
    legal/
      trustandcompliance/
        Report-report.pdf
```

This layout is the source attribution: the host and source page path show which page produced the PDF links.

## Filename Rules

The filename is based on the link text and original PDF filename:

```text
<link text up to 30 chars>-<original filename>
```

If the link text is empty, SwiftScraper uses only the original filename.

Unsafe filename characters `/`, `\`, `:`, and control characters are replaced with `_`. Duplicate output names receive `-2`, `-3`, and so on.

## User-Agent And Cookies

PDF link discovery happens in WKWebView, but PDF bytes are downloaded with URLSession.

For each PDF download request:

- All `--header` values are applied.
- If `--header "User-Agent: ..."` is present, that explicit User-Agent is used.
- If no User-Agent header is provided, SwiftScraper reads `navigator.userAgent` from WKWebView and applies it to the URLSession request.
- Cookies are read from `WKWebsiteDataStore.httpCookieStore` after rendering.
- Matching cookies are added to the URLSession request as a `Cookie` header using domain, path, secure, and expires checks.
- If `--header "Cookie: ..."` is explicitly provided, it is not overwritten by automatic cookie propagation.

This makes the PDF request closely match the rendered page context without relying on WebKit browser download control.

## Output JSON

`--download-pdfs` writes its JSON summary to stdout.

For single-page runs, check:

- `source.url`
- `source.directory`
- `pdfCount`
- `successCount`
- `failureCount`
- `files[].pdfURL`
- `files[].outputPath`
- `files[].error`

For batch runs and `--download-linked-pdfs`, check:

- `source.kind`
- `source.location`
- `pageCount`
- `pageSuccessCount`
- `pageFailureCount`
- `pages[].url`
- `pages[].sourceDirectory`
- `pages[].files[]`

`--download-linked-pdfs` writes this batch-shaped manifest to `<download-dir>/pdf-downloads.json`.

Exit codes:

- `0`: page processing succeeded and all discovered PDFs downloaded, or no PDF links were found
- `1`: page processing failed or at least one PDF download failed
- `2`: CLI argument error

## Limitations

- Only links whose URL path ends with `.pdf` are included.
- Download endpoints that redirect to PDFs but do not end in `.pdf` are not included.
- Response `Content-Type` is not validated; any 2xx response for a discovered PDF URL is saved.
- BiDi server mode is separate; do not use this skill for browser download control through WebDriver BiDi.
