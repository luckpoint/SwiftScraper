# SwiftScraper

A Swift CLI that uses macOS's native `WKWebView` to capture page content after JavaScript execution.
It handles dynamic pages that a simple `URLSession` fetch cannot fully retrieve, with cookie injection, rendering waits, content extraction, Markdown conversion, and batch execution.

## Features
- Capture the post-JavaScript-rendered DOM with `WKWebView`
- Inject and save session state with `--cookie`, `--cookie-file`, and `--cookie-jar`
- Load cookies from existing macOS Chrome or Firefox profiles with `--browser-cookies` (Brave, Windows/Linux, and Firefox containers are unsupported)
- Add custom HTTP headers such as `Accept-Language` with `--header`
- Combine fixed waits, automatic scrolling, selector waits, text waits, and DOM stability waits
- Extract the full HTML, `body` text, selected elements, likely content, or a structure inspection report
- Pretty-print HTML and convert HTML to Markdown
- Collect image features with JavaScript and use Swift heuristics to remove logos and UI images
- Run batches from `sitemap.xml` or a URL file
- Extract `.pdf` links from PDF index pages and save them in site-specific directories, rejecting responses that are not PDFs
- Convert a Markdown file to PDF with `--pdf`
- Start a WebDriver BiDi-style bridge over a SwiftNIO WebSocket server to control WKWebView
- Select the level of exposure with `windowless`, `hidden-window`, or `visible-window`

## Requirements
- macOS 13 or later
- Swift 6.0
- Node.js 24, only for the `npm run puppeteer:*` probe scripts (pinned in `mise.toml`)

Because it uses `WKWebView` and AppKit, SwiftScraper runs only on macOS.
The design aims to minimize user exposure rather than provide a fully headless browser.

## Build
```bash
swift build
```

Release build:

```bash
swift build -c release
```

Generated binary:

```bash
.build/release/swift-scraper
```

### Installation
Install with Homebrew (macOS 13 or later, with Xcode or the Command Line Tools):

```bash
brew tap luckpoint/swift-scraper
brew install swift-scraper
```

Build a release from source and install it at `~/.local/bin/swift-scraper`:

```bash
./scripts/install.sh
```

Set `BIN_DIR` to change the installation directory:

```bash
BIN_DIR="$HOME/bin" ./scripts/install.sh
```

### Security checks
Install the local scanners with Homebrew:

```bash
brew install gitleaks osv-scanner
```

Run both checks before publishing changes:

```bash
./scripts/security-scan.sh
```

GitHub Actions runs the same checks on pull requests and pushes to `main`, and
also runs a scheduled dependency scan. Gitleaks scans the repository history;
OSV-Scanner scans supported dependency manifests, including `Package.resolved`
and `package-lock.json`.

## Usage
### Basic
```bash
swift run swift-scraper -- https://example.com
```

When invoked through `swift run`, include `--` before the CLI options.

### Main options
```text
--bidi-server                  Start the WKWebView BiDi bridge server
--bidi-host <host>             BiDi server bind host; defaults to 127.0.0.1
--bidi-port <port>             BiDi server bind port; defaults to 9222
--url <url>                    Set the target URL explicitly
--cookie <spec>                Add one cookie
--cookie-file <path>           Load cookies from JSON
--cookie-jar <path>            Load CookieJar JSON and save it after execution
--browser-cookies <browser>    Load cookies from macOS Chrome or Firefox
--browser-profile <name|path>  Browser profile name or path; defaults to the default profile
--header <Name: Value>         Add an HTTP header; may be specified multiple times
--persistent-store             Use a persistent DataStore
--visibility <mode>            windowless | hidden-window | visible-window
--viewport <width>x<height>    WebView size; defaults to 1440x900
--wait-delay <seconds>         Fixed wait after didFinish
--auto-scroll                  Scroll downward to help trigger lazy loading
--wait-selector <css>          Wait for a CSS selector; may be specified multiple times
--wait-text <text>             Wait for text; may be specified multiple times
--poll-interval <seconds>      Condition polling interval; defaults to 0.5
--dom-stable-delay <seconds>   Time before the DOM is considered stable; defaults to 0.5
--load-timeout <seconds>       Load-stage timeout; defaults to 30
--wait-timeout <seconds>       Rendering wait timeout; defaults to 15
--js-timeout <seconds>         evaluateJavaScript timeout; defaults to 10
--sitemap                      Follow the target site's sitemap.xml for multiple URLs
--url-file <path>              Read one URL per line from a file
--concurrency <count>          Batch concurrency; defaults to 4
--output <path>                Save to a file instead of standard output
--download-pdfs <directory>    Save PDF links found on the page
--download-linked-pdfs <dir>   Save PDF links alongside normal extraction
--overwrite-pdfs               Replace existing PDFs instead of avoiding name collisions
--max-pdf-size <megabytes>     Reject PDFs above this size before writing; defaults to 100 (1 MB = 1048576 bytes)
--body-text                    Extract document.body.innerText
--selector-inner-html <css>    Extract innerHTML from selected elements
--content-only                 Extract content HTML without header, footer or sidebar
--inspect-structure            Inspect page structure and content candidates without dumping HTML
--markdown                     Convert HTML extraction results to Markdown
--extract-images               Apply image heuristics to narrow images in HTML output
--image-filter <mode>          all | article-only
--image-score-threshold <0-1>  Keep threshold; defaults to 0.65
--image-include-maybe          Keep images classified as maybe
--image-debug                  Write image scores and reasons as JSON to stderr
--pretty-print                 Format HTML output with SwiftSoup
--pdf <file.md>                Convert a Markdown file to PDF
--verbose                      Write progress logs to stderr
--version                      Show the version
--help                         Show this help
```

## Examples
### 1. Extract the full HTML
```bash
swift run swift-scraper -- https://example.com --output out/page.html
```

### 2. Convert likely content to Markdown
```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --output out/article.md
```

### 3. Wait for rendering
```bash
swift run swift-scraper -- \
  https://example.com/app \
  --auto-scroll \
  --wait-selector "#app" \
  --wait-text "Loaded" \
  --wait-timeout 20 \
  --dom-stable-delay 1.0
```

### 4. Keep only content images
```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --extract-images \
  --image-filter article-only \
  --image-debug
```

With `--extract-images`, image heuristics run before HTML or Markdown conversion and images classified as `drop` are removed from the output. `--image-debug` writes scores and reasons as JSON to stderr.

### 5. Save PDFs from a PDF index page
```bash
swift run swift-scraper -- \
  https://www.okta.com/legal/trustandcompliance/ \
  --download-pdfs downloads \
  --auto-scroll
```

PDFs are saved under `downloads/<host>/<source-path>/`. In this example, the directory is `downloads/www.okta.com/legal/trustandcompliance/`.

File names are built from the link text and original file name. Link text is whitespace-normalized and truncated to 30 characters. If the link text is empty, only the original file name is used.

```text
Okta Model Card Governance Ana-okta-model-card-governance-analyzer-2026-02-13.pdf
```

When a file with the same name already exists, a suffix such as `-2` or `-3` is normally added. Use `--overwrite-pdfs` to replace an existing PDF with the same name. If multiple links produce the same name in one run, the second and later files receive numeric suffixes even with overwrite enabled.

The result is written as JSON to stdout and includes the output directory, success and failure counts, and the URL and path for each PDF. `--cookie`, `--cookie-file`, `--cookie-jar`, `--header`, and rendering wait options also apply to PDF link extraction.

PDF files are downloaded with `URLSession`. Cookies are read from `WKWebsiteDataStore.httpCookieStore` after rendering and matching cookies are applied to the `Cookie` header for the PDF URL. If `--header 'User-Agent: ...'` is set, that value takes precedence; otherwise, the WebView's `navigator.userAgent` is read and added to the PDF request.

`--download-pdfs` can be combined with `--sitemap` or `--url-file`. Each page is rendered, only its PDF links are saved, and the batch PDF download result JSON is written to stdout.

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --download-pdfs downloads \
  --concurrency 4
```

To keep the normal extraction result as well, use `--download-linked-pdfs <dir>`. Normal scrape output on stdout or at `--output` is preserved, and the PDF download result is saved to `<dir>/pdf-downloads.json`.

```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/docs.md
```

### 6. Inject a cookie directly
```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --cookie 'name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true'
```

### 7. Use a cookie JSON file
```json
[
  {
    "name": "session",
    "value": "abc123",
    "domain": "example.com",
    "path": "/",
    "secure": true,
    "httpOnly": true
  }
]
```

```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --cookie-file cookies.json
```

### 8. Use a CookieJar JSON file
If the file passed to `--cookie-jar` exists, cookies are injected before loading and the cookies remaining in WebKit's CookieStore are saved back to the same JSON file after execution. If the file does not exist, it is treated as an empty CookieJar and created after execution.

```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --cookie-jar cookies.json
```

CookieJar uses the same format as `--cookie-file` and is written as a JSON array. It cannot be used for batch execution with `--sitemap` or `--url-file`.

### 9. Use cookies from an existing browser profile

macOS 13 or later is supported with Chrome and Firefox. You may specify a profile name or profile directory path. If omitted, Chrome's `Default` profile or Firefox's default profile from `profiles.ini` is used.

```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --browser-cookies chrome \
  --browser-profile "Profile 1"
```

Firefox resolves relative and absolute `Path` values from `profiles.ini`. Firefox containers, partitioned cookies, Brave, and Windows/Linux profiles are unsupported. Chrome encrypted cookies can be used only when SwiftScraper can access Chrome Safe Storage in the macOS Keychain and decrypt a tested encryption format. Keychain denial or unsupported formats produces an error without printing cookie values.

Browser cookies are read once per command. For each batch page, the in-memory cookie definitions are applied according to the URL's domain, path, expiry, and secure rules. Explicit cookies from `--cookie` and `--cookie-file` take precedence over browser cookies, and `--browser-cookies` cannot be combined with `--cookie-jar`.

### 10. Send custom HTTP headers
```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --header 'Accept-Language: en,en-US;q=0.9' \
  --header 'X-Custom-Header: value'
```

Use this to force an English version with `Accept-Language` on sites that redirect according to locale detection.

### 11. Run a batch from a sitemap
```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --content-only \
  --markdown \
  --concurrency 8 \
  --output out/sitemap-batch.json
```

### 12. Run a batch from a URL file
`urls.txt`:

```text
https://example.com/one
https://example.com/two
# comment
https://example.com/three
```

```bash
swift run swift-scraper -- \
  --url-file urls.txt \
  --inspect-structure \
  --concurrency 3 \
  --output out/url-file-batch.json
```

### 13. Start the WebDriver BiDi bridge
`--bidi-server` starts a SwiftNIO WebSocket server so external programs can control the `WKWebView` in the same process with JSON commands. The endpoint is `ws://127.0.0.1:9222/session`.

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-port 9222 \
  --verbose
```

To specify an initial URL:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --url https://example.com \
  --visibility hidden-window
```

Main supported methods:
- `session.status`
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
- `emulation.setScreenOrientationOverride` compatibility no-op
- `swiftScraper:scrape.getHTML` / `scrape.getHTML`
- `swiftScraper:scrape.getText` / `scrape.getText`
- `swiftScraper:scrape.waitForSelector`
- `swiftScraper:scrape.waitForText`
- `swiftScraper:scrape.waitForFunction`
- `swiftScraper:scrape.waitForDOMStable`
- `swiftScraper:scrape.autoScroll`
- `swiftScraper:scrape.extract`
- `swiftScraper:scrape.getCookies` / `scrape.getCookies`
- `log.entryAdded` event

To verify P0/P1 and the SwiftScraper scraping extension without depending on external sites:

```bash
npm install
npm run puppeteer:bidi-p1
```

This bridge controls WKWebView over WebSocket for scraping. It is not a fully compatible Chrome or Firefox WebDriver BiDi browser implementation. See [11. WebDriver BiDi Bridge](docs/11-webdriver-bidi-bridge.md) for details.

#### Access control

The bridge grants full control of the `WKWebView` — arbitrary JavaScript, cookies, navigation — to anyone who can open the WebSocket, so connections are filtered before the upgrade:

- Requests carrying an `Origin` header are refused. WebSockets are exempt from the same-origin policy, so without this any page you visit while the server runs could connect to `ws://127.0.0.1:9222/session` and drive the browser. Non-browser clients such as `puppeteer-core` send no `Origin` and are unaffected.
- The `Host` header must be present and name a loopback endpoint (`127.0.0.1`, `::1`, or `localhost`), which blocks DNS rebinding.
- `browsingContext.navigate` accepts only `http`, `https`, and `about` URLs, so a connected client cannot read local files through `file://`.

Every connection requires `Authorization: Bearer <token>` during the WebSocket handshake.
On each start, the server generates a new 256-bit token and prints the path of its
owner-readable token file (0600 in a 0700 directory). The token itself is never
logged. The generated directory is removed on normal shutdown, including Ctrl+C
(SIGINT) and SIGTERM. SIGKILL, crashes, or power loss can leave files behind,
but the next run uses a new token. Signal exits use status 130/143 respectively.

Only `127.0.0.1`, `::1`, and `localhost` are accepted for `--bidi-host`.
`localhost` binds to `127.0.0.1`. Remote access requires an SSH tunnel to the
loopback listener and secure transfer of the token. Do not expose the listener
through an unauthenticated proxy. Tokens grant full access to this WKWebView,
including imported cookies; they do not isolate hostile processes running under
your own OS account.

The bundled Puppeteer clients automatically discover the matching local server
in the current user's temporary directory; no environment variable is required.
Discovery matches the endpoint's host and port, checks private file permissions
and a live process, and refuses missing or ambiguous matches. Both processes must
use the same temporary directory. Stale files from an exited process are ignored.

For an SSH tunnel, a different temporary directory, or ambiguous discovery,
explicitly set the file path printed by the server (this takes precedence):

```bash
export SWIFTSCRAPER_BIDI_TOKEN_FILE=/path/printed/by/server/token
npm run puppeteer:bidi-p1
```

Custom clients must supply the Authorization header without an Origin header.
The server permits four TCP connections, eight in-flight requests per connection,
a 10-second handshake, 16 KiB text frames (fragmentation is unsupported), and
responses/events up to 8 MiB. Excess traffic or output closes the connection.
Output limits apply after serialization; they are not a hard memory limit on
WebKit. JavaScript timeouts bound waiting, not guaranteed termination of scripts.

Run the local security integration checks (starts its own temporary server and
does not use your browser profile):

```bash
swift build
npm ci
npm run test:bidi-security
```

## Extraction modes
| Mode | Description |
| --- | --- |
| Default | `document.documentElement.outerHTML` |
| `--body-text` | `document.body.innerText` |
| `--selector-inner-html <css>` | `innerHTML` of matching elements |
| `--content-only` | Extract likely content only |
| `--inspect-structure` | Produce a text report of content candidates, landmark counts, and removal details |

Constraints:
- `--markdown` is available only for extraction modes that return HTML
- `--extract-images` is available only for extraction modes that return HTML
- `--markdown` and `--pretty-print` cannot be used together
- `--selector-inner-html` fails when the target element is not found
- `--auto-scroll` affects only document-level scrolling; internal scroll containers may need separate handling

## Batch output
The final output of batch execution is JSON. Each page's success or failure appears in `pages[]`.

```json
{
  "source": {
    "kind": "url-file",
    "location": "/path/to/urls.txt"
  },
  "pageCount": 2,
  "successCount": 1,
  "failureCount": 1,
  "pages": [
    {
      "url": "https://example.com/one",
      "success": true,
      "output": "<html>...</html>",
      "error": null
    },
    {
      "url": "https://example.com/two",
      "success": false,
      "output": null,
      "error": "Page load failed"
    }
  ]
}
```

Exit codes:
- `0`: success
- `1`: runtime failure or at least one failed page in the batch
- `2`: CLI argument error

## Release
1. Update `SwiftScraperVersion.current` in `Sources/SwiftScraperCore/Version.swift`, commit, and push to `main`
2. Push a tag with the same version

```bash
git tag v0.1.0
git push origin v0.1.0
```

Pushing the tag starts `.github/workflows/release.yml`. If the tag matches `SwiftScraperVersion.current`, the workflow updates the formula's `url` and `sha256` in [luckpoint/homebrew-swift-scraper](https://github.com/luckpoint/homebrew-swift-scraper).
The workflow needs a PAT that can write to the tap, stored as the `HOMEBREW_TAP_GITHUB_TOKEN` secret.

On failure:
- Version mismatch (the tap is not updated): `git tag -d v0.1.0 && git push --delete origin v0.1.0` → fix the constant, commit and push, then recreate and push the same tag
- Formula update failure (for example, an expired PAT): `gh secret set HOMEBREW_TAP_GITHUB_TOKEN` → `gh run rerun <run-id> --failed`

## Documentation
- [01. Page Loading](docs/01-page-loading.md)
- [02. Cookie Injection](docs/02-cookie-injection.md)
- [03. Rendering Wait](docs/03-rendering-wait.md)
- [04. HTML / DOM Extraction](docs/04-html-dom-extraction.md)
- [05. Limiting User Exposure](docs/05-user-visibility-control.md)
- [06. Stability and Timeout Control](docs/06-stability-and-timeout.md)
- [07. Debug Operability](docs/07-debug-operability.md)
- [08. Batch Processing](docs/08-batch-processing.md)
- [09. Image Extraction and Heuristics](docs/09-image-extraction.md)
- [10. PDF Generation](docs/10-pdf-generation.md)
- [11. WebDriver BiDi Bridge](docs/11-webdriver-bidi-bridge.md)
- [12. PDF Link Download](docs/12-pdf-link-download.md)

### Planning documents
These describe intended direction, not shipped behavior. Command examples in them may use options that do not exist yet.

- [00. Initial Design](docs/00-initial-design.md)
- [13. Knowledge Base Improvement Roadmap](docs/13-knowledge-base-roadmap.md)
- [14. Search Result Discovery](docs/14-search-discovery.md)
- [15. Knowledge Base Source Artifact Specification](docs/15-kb-source-spec.md)

## Constraints
- macOS only
- Gzip-compressed sitemaps (`.xml.gz`) are recognized by URL but their contents are not decompressed
- `windowless` and `hidden-window` reduce exposure but do not guarantee a fully headless environment
- The initial image heuristic implementation makes decisions per page; batch frequency adjustment and domain-specific blacklists are not implemented
- `--download-pdfs` and `--download-linked-pdfs` target only links whose `href` path ends in `.pdf`. Support for download endpoints whose paths do not end in `.pdf` is a future candidate with no scheduled implementation date
- The WebDriver BiDi bridge is a scraping subset rather than a full WebDriver BiDi implementation
