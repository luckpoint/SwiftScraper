---
name: swiftscraper-pdf-download
description: Use this skill when the user wants SwiftScraper to download PDF files from a rendered PDF link-list page. This skill covers the `--download-pdfs` CLI mode, WKWebView DOM-based PDF link discovery, site/path-based output directories, link-text-derived filenames, User-Agent and Cookie propagation from WKWebView to URLSession, and troubleshooting PDF download failures.
---

# SwiftScraper PDF Download

Use this skill for one-shot PDF downloads from pages that list PDF links, such as legal, trust, compliance, or documentation pages.

This is a CLI workflow, not a WebDriver BiDi browser download workflow.

## Command

From the SwiftScraper repository root:

```bash
swift run swift-scraper -- \
  https://example.com/legal/trust/ \
  --download-pdfs downloads \
  --auto-scroll
```

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

## How Links Are Found

SwiftScraper loads the page in WKWebView, applies cookies/headers, waits for rendering, then evaluates JavaScript against the rendered DOM.

The extraction script scans:

```js
document.querySelectorAll('a[href]')
```

It keeps links whose resolved URL uses `http:`, `https:`, or `file:` and whose path ends with `.pdf` case-insensitively. It also deduplicates exact PDF URLs after removing fragments.

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

The command writes a JSON summary to stdout. Check:

- `source.url`
- `source.directory`
- `pdfCount`
- `successCount`
- `failureCount`
- `files[].pdfURL`
- `files[].outputPath`
- `files[].error`

Exit codes:

- `0`: page processing succeeded and all discovered PDFs downloaded, or no PDF links were found
- `1`: page processing failed or at least one PDF download failed
- `2`: CLI argument error

## Limitations

- Single-page mode only. `--sitemap` and `--url-file` are not supported with `--download-pdfs`.
- Only links whose URL path ends with `.pdf` are included.
- Download endpoints that redirect to PDFs but do not end in `.pdf` are not included.
- Response `Content-Type` is not validated; any 2xx response for a discovered PDF URL is saved.
