# 12. PDF Link Download

## Purpose
Render PDF index pages and ordinary scraping targets in `WKWebView`, extract `.pdf` links from the rendered DOM, and save them locally.

There are two modes: a dedicated mode that saves only PDFs, and a sidecar mode that saves PDFs alongside a normal scrape.

| Mode | Use | PDF result |
| --- | --- | --- |
| `--download-pdfs <dir>` | Save only PDFs from a PDF index page | JSON on stdout |
| `--download-linked-pdfs <dir>` | Scrape normally and also save PDFs found on each page | `<dir>/pdf-downloads.json` |

## Examples
Save PDFs from a single PDF index page:

```bash
swift run swift-scraper -- \
  https://www.okta.com/legal/trustandcompliance/ \
  --download-pdfs downloads \
  --auto-scroll
```

Traverse multiple pages from a sitemap and save only their PDFs:

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --download-pdfs downloads \
  --concurrency 4
```

Save PDFs alongside a normal scrape:

```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/docs.md
```

Save PDFs alongside a batch scrape from a URL file:

```bash
swift run swift-scraper -- \
  --url-file urls.txt \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/pages.json
```

## Inputs
The following page-loading options are shared:

- `--cookie`
- `--cookie-file`
- `--browser-cookies chrome|firefox` / `--browser-profile <name|path>`
- `--header`
- `--wait-delay`
- `--auto-scroll`
- `--wait-selector`
- `--wait-text`
- `--poll-interval`
- `--dom-stable-delay`
- `--load-timeout`
- `--wait-timeout`
- `--js-timeout`
- `--visibility`
- `--viewport`
- `--persistent-store`
- `--overwrite-pdfs`
- `--max-pdf-size`

`--download-pdfs` can be combined with `--sitemap`, `--url-file`, and `--concurrency`. `--concurrency` is effective only when used with batch input.

`--download-linked-pdfs` is an additional normal-scrape option, so it can be combined with `--content-only`, `--markdown`, `--output`, `--sitemap`, and `--url-file`.

`--cookie-jar` is available for single-page execution but cannot be used with `--sitemap` or `--url-file` batch execution.
Browser cookies are supported only for macOS Chrome and Firefox. Explicit cookies from `--cookie` and `--cookie-file` take precedence, and `--browser-cookies` cannot be combined with `--cookie-jar`.

## Output directory
Under the specified root directory, PDFs are stored in a directory derived from the source page's host and path.

```text
downloads/
  www.okta.com/
    legal/
      trustandcompliance/
        <file>.pdf
```

A PDF extracted from `https://www.okta.com/legal/trustandcompliance/` is stored in `downloads/www.okta.com/legal/trustandcompliance/`.

For multiple pages, each source path gets its own directory, so the folder structure identifies the site and page that produced a PDF.

## File names
File names are generated as follows:

1. Use the final path component of the PDF URL as the original file name
2. When link text is present, use `<link text>-<original file name>.pdf`
3. Normalize whitespace in link text and truncate it to 30 characters
4. If link text is empty, use only the original file name
5. Replace `/`, `\\`, `:`, and control characters with `_`
6. Add `-2`, `-3`, and so on when a file with the same name already exists

With `--overwrite-pdfs`, replace an existing file with the same name instead of adding a suffix. If multiple PDF links produce the same name during one run, the second and later links still receive suffixes even with overwrite enabled.

## Response validation

A downloaded response is checked before it is written to disk:

- It must begin with the `%PDF-` header. A site that answers `200 OK` with an HTML error page for a `.pdf` URL is rejected instead of being saved under a `.pdf` name.
- It must not exceed `--max-pdf-size`, which defaults to 100 megabytes, where 1 megabyte is 1048576 bytes.

The header is checked first, so an oversized HTML page is reported as not being a PDF rather than as being too large.

A rejected link fails on its own. The run continues, the manifest records `success: false` with the reason, and the process still exits with status 1 because the failure count is non-zero. Because the manifest fills in `outputPath` for failures as well, read `success` rather than the presence of a path.

The size limit rejects a response before it is written to disk; it does not stop it from being downloaded. `URLSession` buffers the whole body in memory before the check runs.

Links with a `file://` URL are copied without validation, since they name a file the caller chose.

Examples:

```text
Okta Model Card Governance Ana-okta-model-card-governance-analyzer-2026-02-13.pdf
report.pdf
report-2.pdf
```

## Processing overview
1. Load the target page in the same `WKWebView` used for normal scraping
2. Apply cookies, headers, visibility mode, viewport, and wait options
3. After rendering waits, enumerate links with `document.querySelectorAll('a[href]')`
4. Keep only `http:`, `https:`, or `file:` URLs whose path ends in `.pdf`
5. Remove URL fragments and duplicate URLs
6. Read the actual WKWebView user agent from `navigator.userAgent`
7. Apply cookies remaining in WebKit's CookieStore to PDF download requests
8. Download PDFs with `URLSession`, reject responses that fail validation, and save the rest under the source page's directory
9. `--download-pdfs` writes JSON to stdout; `--download-linked-pdfs` saves a manifest at `<dir>/pdf-downloads.json`

`--download-linked-pdfs` does not load the page twice. It collects PDF links during the same `WKWebView` execution as normal extraction and saves the PDFs afterward.

## User-Agent and cookies
PDF link extraction uses the rendered DOM in WKWebView, while PDF files are fetched with `URLSession`.

The `URLSession` PDF download request receives:

- Any headers specified with `--header`
- The value from `--header 'User-Agent: ...'` when provided
- The `navigator.userAgent` read from WKWebView when no User-Agent was specified
- Cookies from WebKit's `WKWebsiteDataStore.httpCookieStore` that match the PDF URL's domain, path, secure, and expiry rules

Cookies are sent in the `Cookie` header. If `--header 'Cookie: ...'` is explicitly set, that value takes precedence and the automatically generated Cookie header is not used.

As a result, cookies added to WebKit's CookieStore after login or locale detection are also used for PDF downloads. `URLSession` is not the same browser download mechanism as WebKit, so equivalent headers and cookies are reconstructed explicitly.

## Output JSON
For a single-page `--download-pdfs` run, stdout contains every PDF result, including failures.

```json
{
  "failureCount": 0,
  "files": [
    {
      "error": null,
      "linkText": "Report",
      "originalFilename": "report.pdf",
      "outputPath": "/path/to/downloads/example.com/legal/Report-report.pdf",
      "pdfURL": "https://example.com/files/report.pdf",
      "success": true
    }
  ],
  "outputDirectory": "/path/to/downloads",
  "pdfCount": 1,
  "source": {
    "directory": "/path/to/downloads/example.com/legal",
    "url": "https://example.com/legal/"
  },
  "successCount": 1
}
```

Batch `--download-pdfs` and the `--download-linked-pdfs` manifest include per-page results.

```json
{
  "failureCount": 0,
  "outputDirectory": "/path/to/downloads",
  "pageCount": 1,
  "pageFailureCount": 0,
  "pageSuccessCount": 1,
  "pages": [
    {
      "error": null,
      "failureCount": 0,
      "files": [],
      "pdfCount": 0,
      "sourceDirectory": "/path/to/downloads/example.com/docs",
      "success": true,
      "successCount": 0,
      "url": "https://example.com/docs/"
    }
  ],
  "pdfCount": 0,
  "source": {
    "kind": "url-file",
    "location": "/path/to/urls.txt"
  },
  "successCount": 0
}
```

Exit codes:

- `0`: page retrieval and PDF downloads succeeded, or there were no PDF links
- `1`: page retrieval failed, the output directory could not be created, or some or all PDFs failed to save
- `2`: CLI argument error

With `--download-linked-pdfs`, exit code 1 is returned if either normal scraping or PDF downloading has a failure. Normal scrape output and the PDF manifest are kept separate.

## Incompatible options
`--download-pdfs` is a PDF-only mode and is separate from normal extraction output.

- `--pdf`
- `--bidi-server`
- `--download-linked-pdfs`
- `--output`
- `--body-text`
- `--selector-inner-html`
- `--content-only`
- `--inspect-structure`
- `--markdown`
- `--extract-images`
- `--image-filter`
- `--image-score-threshold`
- `--image-include-maybe`
- `--image-debug`
- `--pretty-print`

`--download-linked-pdfs` is an additional normal-scrape option but cannot be combined with:

- `--pdf`
- `--bidi-server`
- `--download-pdfs`

## Constraints
- Only links whose `href` path ends in `.pdf` are selected. Download endpoints that redirect to a PDF are not supported.
- PDF `Content-Type` is not validated. A response is saved when its HTTP status is 2xx.
- This is implemented as a CLI one-shot or batch mode, not as download control in the BiDi server.

## Future candidates
Support for sites where a non-`.pdf` download endpoint returns a PDF remains a future candidate. There is no scheduled implementation date; it can be considered when needed.

Sending `HEAD` or `GET` to every link can add significant load and latency, so any implementation should be an opt-in, lightweight probe.

Possible design:

1. Continue accepting links with a `.pdf` path immediately
2. Use DOM information to narrow non-`.pdf` links to likely PDF candidates
3. Try `HEAD` only for those candidates
4. If `HEAD` returns 405, 403, or insufficient information, try `GET` with `Range: bytes=0-1023`
5. Promote only responses identified as PDFs by `Content-Type: application/pdf` or a PDF filename in `Content-Disposition`

Examples of candidate signals:

- `a[download]`
- `a[type="application/pdf"]`
- `pdf`, `download`, `report`, `document`, or `whitepaper` in `href`, link text, `aria-label`, or `title`
- Paths resembling download endpoints, such as `/download`, `/asset`, `/file`, or `/documents/`

Possible safeguards:

- Keep current behavior by default and enable probing only with an explicit option
- Cap the number of probes per page
- Use short timeouts and low concurrency
- Cache probe results across the batch
- Probe each URL only once after removing its fragment
