# 11. WebDriver BiDi Bridge

## Purpose
Allow an external program to control SwiftScraper's `WKWebView` over WebSocket and JSON, including URL navigation, JavaScript execution, and HTML or text extraction.

This is a scraping bridge modeled after WebDriver BiDi. It does not turn WKWebView into a fully compliant WebDriver BiDi browser.

```text
external client
  -> WebSocket / JSON
SwiftNIO BiDi server
  -> BiDiDispatcher
  -> BiDiWebViewHost
  -> WKWebView
```

## Starting the server
The default endpoint is `ws://127.0.0.1:9222/session`.

```bash
swift run swift-scraper -- \
  --bidi-server \
  --verbose
```

To change the bind host or port:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-host 127.0.0.1 \
  --bidi-port 9333
```

To load an initial URL before accepting connections:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --url https://example.com \
  --visibility hidden-window
```

## Smoke test with Puppeteer
The minimal probe for checking a Puppeteer WebDriver BiDi connection is:

```bash
npm install
swift run swift-scraper -- \
  --bidi-server \
  --verbose \
  --visibility hidden-window
```

In another shell:

```bash
npm run puppeteer:bidi-p1
```

`puppeteer:bidi-p1` starts a temporary HTTP server and fixture HTML on `127.0.0.1`, then checks `session.subscribe`, the `wait` option of `browsingContext.navigate`, `script.addPreloadScript` / `removePreloadScript`, `browsingContext.captureScreenshot`, `browsingContext.setViewport`, the runtime cookie API, JavaScript error responses, and SwiftScraper extension scraping commands without relying on an external site.

Probe scraping against a live site:

```bash
npm run puppeteer:google
```

The probe connects to `ws://127.0.0.1:9222/session` with `puppeteer-core`, opens Google, enters `Apple Swift` in the search input, submits the search, and extracts result links.

A Yahoo! JAPAN probe is also available when Google bot detection should be avoided:

```bash
npm run puppeteer:yahoo
```

The Yahoo! JAPAN probe opens `https://www.yahoo.co.jp/`, enters `Apple Swift` in the search input, submits the search, and extracts result links from `search.yahoo.co.jp`.

To change the endpoint or query:

```bash
SWIFTSCRAPER_BIDI_ENDPOINT=ws://127.0.0.1:9333/session \
GOOGLE_QUERY="Apple Swift" \
npm run puppeteer:google
```

```bash
SWIFTSCRAPER_BIDI_ENDPOINT=ws://127.0.0.1:9333/session \
YAHOO_QUERY="Apple Swift" \
npm run puppeteer:yahoo
```

If Google returns a bot-detection page such as `/sorry`, the bridge and Puppeteer connection may still be working even though no result list can be obtained. In that case, the probe prints the bot-detection URL and part of the page text before failing.

To approximate Safari's User-Agent, specify a `User-Agent` header. In BiDi server mode, this value is applied both to navigation request headers and to `WKWebView.customUserAgent`.

```bash
SAFARI_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15'

swift run swift-scraper -- \
  --bidi-server \
  --verbose \
  --visibility visible-window \
  --header "User-Agent: $SAFARI_UA"
```

## Main compatible options
- `--url <url>`: URL to open first at startup
- `--cookie <spec>` / `--cookie-file <path>`: inject explicit cookies at startup
- `--browser-cookies chrome|firefox` / `--browser-profile <name|path>`: import cookies from an existing macOS Chrome or Firefox profile at startup; the cookie database is read only once
- `--browser-cookies` and `--cookie-jar` cannot be used together; explicit cookies take precedence over browser cookies
- `--header <Name: Value>`: add an HTTP header to navigation requests; `User-Agent` is also applied to `WKWebView.customUserAgent`
- `--persistent-store`: use a persistent `WKWebsiteDataStore`
- `--visibility <mode>`: `windowless` / `hidden-window` / `visible-window`. `visible-window` brings a `SwiftScraper BiDi` window to the front as a normal window at startup. Closing it hides only the window and does not stop the server
- `--viewport <width>x<height>`: WebView size
- `--load-timeout <seconds>`: navigation timeout
- `--js-timeout <seconds>`: JavaScript execution timeout

When checking `visible-window`, specify an initial URL so that the window shows page content instead of `about:blank`.

```bash
swift run swift-scraper -- \
  --bidi-server \
  --verbose \
  --visibility visible-window \
  --url https://www.yahoo.co.jp/
```

## Incompatible options
The BiDi server is a long-running interaction mode and is separate from one-shot scraping, batch processing, PDF output, and PDF link downloading.

- `--pdf`
- `--download-pdfs`
- `--download-linked-pdfs`
- `--sitemap`
- `--url-file`
- `--concurrency`
- `--cookie-jar`
- `--output`
- `--body-text`
- `--selector-inner-html`
- `--content-only`
- `--inspect-structure`
- `--markdown`
- `--extract-images`
- `--pretty-print`

## Supported methods

### WebDriver BiDi-compatible methods

| method | Description |
| --- | --- |
| `session.status` | Return the server ready state |
| `session.new` | Return a minimal session-creation response for Puppeteer compatibility |
| `session.end` | Compatibility no-op that returns success for client compatibility |
| `session.subscribe` | Register event subscriptions for a client |
| `session.unsubscribe` | Remove event subscriptions for a client |
| `browser.getUserContexts` | Return the single `default` user context |
| `browser.close` | Compatibility no-op; the server process remains running |
| `browsingContext.getTree` | Return the single `main` context |
| `browsingContext.navigate` | Navigate to a URL; `wait` supports `none`, `interactive`, and `complete` |
| `browsingContext.reload` | Reload the current URL; `wait` supports `none`, `interactive`, and `complete` |
| `browsingContext.captureScreenshot` | Return a base64-encoded PNG screenshot of the current viewport |
| `browsingContext.setViewport` | Change the `WKWebView` frame size at runtime |
| `script.evaluate` | Evaluate an expression with `WKWebView.evaluateJavaScript` / `callAsyncJavaScript` |
| `script.callFunction` | Execute a function declaration and arguments in the page world |
| `script.addPreloadScript` | Add a document-start script for future documents |
| `script.removePreloadScript` | Remove an added preload script |
| `storage.getCookies` | Get runtime cookies from `WKHTTPCookieStore` |
| `storage.setCookie` | Add or update a runtime cookie |
| `storage.deleteCookies` | Delete runtime cookies matching name, domain, and path filters |
| `emulation.setScreenOrientationOverride` | Compatibility no-op for Puppeteer's `page.setViewport` |

### SwiftScraper extension methods

The official names use the WebDriver BiDi extension module form `swiftScraper:scrape.*`. Existing `scrape.*` names remain as short aliases.

| method | Description |
| --- | --- |
| `swiftScraper:scrape.getHTML` | Return `document.documentElement.outerHTML` |
| `swiftScraper:scrape.getText` | Return `document.body.innerText` |
| `swiftScraper:scrape.waitForSelector` | Poll until a selector appears |
| `swiftScraper:scrape.waitForText` | Poll until the requested text appears in the document text |
| `swiftScraper:scrape.waitForFunction` | Poll until a JavaScript expression is truthy |
| `swiftScraper:scrape.waitForDOMStable` | Wait until the DOM snapshot remains unchanged for a period |
| `swiftScraper:scrape.autoScroll` | Scroll by viewport units and wait for the bottom and scroll height to stabilize |
| `swiftScraper:scrape.extract` | Run the SwiftScraper extraction engine from server mode |
| `swiftScraper:scrape.getCookies` | Runtime cookie retrieval alias for `storage.getCookies` |
| `swiftScraper:scrape.setCookie` | Runtime cookie configuration alias for `storage.setCookie` |
| `swiftScraper:scrape.deleteCookies` | Runtime cookie deletion alias for `storage.deleteCookies` |

## Supported scope

This bridge implements a scraping-oriented subset of WebDriver BiDi and the minimum compatibility needed for a Puppeteer connection. Full compatibility as a standard BiDi browser is not a goal.

### Transport and session
- The only WebSocket endpoint is `/session`; the default is `ws://127.0.0.1:9222/session`
- Support WebSocket text-frame JSON requests and responses
- Requests require an `id` command; event-style commands without an `id` are rejected
- Responses use `type: "success"` or `type: "error"`
- `session.status` returns the ready state
- `session.new` returns the minimum capabilities needed to initialize Puppeteer's pure WebDriver BiDi connection
- `session.subscribe` and `session.unsubscribe` keep event subscription state per WebSocket client
- `session.subscribe` accepts simple module names such as `log` and `browsingContext` as well as event names
- `session.end` is a compatibility no-op

### Browser and user context
- The only user context is `default`
- `browser.getUserContexts` returns only `default`
- `browser.close` is a compatibility no-op; the server process does not exit

### Browsing context and navigation
- The only browsing context is `main`
- `browsingContext.getTree` returns a single tree for `main`
- `browsingContext.navigate` navigates with `WKWebView.load` or `loadFileURL`
- `browsingContext.reload` reloads the current URL
- `wait` supports `none`, `interactive`, and `complete`; the default is `complete` to preserve existing behavior
- `interactive` is an approximation implemented by hooking `DOMContentLoaded` with a document-start user script
- `complete` waits for `WKNavigationDelegate.webView(_:didFinish:)`
- Navigation returns a simple `navigation` ID
- Send `browsingContext.navigationStarted` to subscribed clients during navigation
- Send `browsingContext.domContentLoaded` to subscribed clients at the approximate DOMContentLoaded point
- Send `browsingContext.load` to subscribed clients when navigation completes
- Send `browsingContext.navigationFailed` to subscribed clients when navigation fails
- `browsingContext.captureScreenshot` captures the current viewport with `WKWebView.takeSnapshot`; full-page screenshots are unsupported
- `browsingContext.setViewport` updates the `WKWebView` frame and the visible window content size

### Script
- `script.evaluate` evaluates an expression in the page world
- `awaitPromise: true` uses `WKWebView.callAsyncJavaScript`
- `script.callFunction` executes `functionDeclaration` and `arguments` in the page world
- `script.addPreloadScript` executes `functionDeclaration` at document start in future documents
- `script.removePreloadScript` removes a preload script matching the script ID
- Preload scripts are not run retroactively in the current document
- Only the `main` value is supported for `target.context`
- Remote values are normalized to `null`, `boolean`, `number`, `string`, `array`, or `object`
- Object remote values are returned as property-tuple arrays compatible with the BiDi deserializer

### Log events
- A document-start user script hooks `console.log`, `info`, `warn`, `error`, and `debug`
- Console output is sent to subscribed clients as `log.entryAdded`

### Custom scraping commands
- `swiftScraper:scrape.*` is SwiftScraper's BiDi extension module; `scrape.*` is a backward-compatible alias
- `swiftScraper:scrape.getHTML` returns `document.documentElement.outerHTML`
- `swiftScraper:scrape.getText` returns `document.body.innerText`
- `swiftScraper:scrape.waitForSelector`, `waitForText`, and `waitForFunction` accept `timeout` and `polling` in milliseconds
- `swiftScraper:scrape.waitForDOMStable` accepts `stableTime`, `timeout`, and `polling` in milliseconds
- `swiftScraper:scrape.autoScroll` uses the same scroll probe as the existing CLI's `--auto-scroll`
- `swiftScraper:scrape.extract` accepts `outerHTML`, `bodyText`, `selectorInnerHTML`, `contentOnly`, or `structureInspection` for `mode`, and `plain` or `markdown` for `format`
- `swiftScraper:scrape.extract` accepts `prettyPrint`, `extractImages`, `imageFilter`, `imageScoreThreshold`, `imageIncludeMaybe`, and `imageDebug`
- `swiftScraper:scrape.getCookies`, `setCookie`, and `deleteCookies` are aliases for the `storage.*` cookie commands

### Startup settings
- Load an initial URL with `--url`
- Inject startup cookies with `--cookie` or `--cookie-file`
- Add navigation request headers with `--header`
- Apply a `User-Agent` header to `WKWebView.customUserAgent` as well
- Use a persistent `WKWebsiteDataStore` with `--persistent-store`
- Set the WebView frame size with `--viewport`
- Show `WKWebView` as a normal window with `--visibility visible-window`

### Storage and cookies
- `storage.getCookies` returns the result of `WKHTTPCookieStore.getAllCookies`
- `storage.setCookie` creates and sets an `HTTPCookie` from a `cookie` object or flat parameters
- `storage.deleteCookies` removes cookies that exactly match `name`, `domain`, and `path` in a `filter` object or flat parameters
- Partitioned cookies and storage keys are unsupported

### Current Puppeteer compatibility
- Support the minimum commands needed to initialize `puppeteer.connect({ browserWSEndpoint, protocol: "webDriverBiDi" })`
- A smoke test centered on DOM operations equivalent to `page.evaluate` and `page.evaluateHandle` works
- `scripts/puppeteer-yahoo-search.mjs` has been verified through result extraction on Yahoo! JAPAN
- This does not guarantee Puppeteer's full high-level API. `page.click`, `page.keyboard`, selector polling, and similar features may reach unsupported BiDi commands, so the current probe is centered on `page.evaluate`

## Unsupported specifications

### Session and browser
- Managing multiple sessions
- Strict specification conformance for event subscriptions
- `browser.createUserContext`
- `browser.removeUserContext`
- Exiting the process through `browser.close`

### Browsing context
- Multiple top-level browsing contexts
- `browsingContext.create`
- `browsingContext.close`
- `browsingContext.activate`
- `browsingContext.print`
- `browsingContext.traverseHistory`
- Full-page screenshots
- Strict tree management for iframes and child contexts
- Complete lifecycle events for `browsingContext.contextCreated` and `contextDestroyed`
- Strict events for fragment navigation, history updates, and navigation committed
- Prompt and dialog handling
- Download control

### Script and realm
- Multiple realms
- Sandbox realms
- Iframe realms
- Worker, shared-worker, and service-worker realms
- Strict sandbox, realm, and context scope for preload scripts
- `script.disown`
- Lifetime management for remote object handles
- DOM-node remote values and shared references
- Complete BiDi-formatted exception details

### Input
- `input.performActions`
- `input.releaseActions`
- Pointer, keyboard, and wheel actions
- File dialog events
- File upload control

### Network
- `network.beforeRequestSent`
- `network.responseStarted`
- `network.responseCompleted`
- `network.fetchError`
- Request interception
- Response body retrieval
- Data collectors
- Cache behavior control
- Authentication challenge handling
- WebSocket and EventSource events

### Storage and cookies
- Partitioned cookies and storage keys
- Detailed cookie attributes such as sameSite, priority, and sourcePort
- Saving with `--cookie-jar` in server mode

### Permissions and emulation
- `permissions.setPermission`
- Geolocation override
- Time-zone override
- Screen-orientation override
- Touch override
- User-agent override command
- Device metrics and media emulation

### CDP and browser-specific extensions
- CDP over BiDi
- `goog:cdp.*`
- `goog:cdp.resolveRealm`
- Chrome- or Firefox-specific capabilities

### Specification notes
- This bridge is for externally controlling `WKWebView` for scraping and is not a WebDriver BiDi conformance target
- Unsupported commands return `unknown command`
- A context other than `main` returns `no such frame`
- JavaScript failures return `javascript error`; the response includes `message` and `stacktrace` when the JavaScript wrapper can obtain them
- Navigation and JavaScript timeouts return `timeout`
- Because of `WKURLSchemeHandler` limitations, ordinary `http` and `https` response bodies are not captured directly at the network layer

## Events
A document-start user script hooks page-level `console.log`, `info`, `warn`, `error`, and `debug`, then sends them as `log.entryAdded` to WebSocket clients that have subscribed with `session.subscribe`.

```json
{
  "type": "event",
  "method": "log.entryAdded",
  "params": {
    "type": "console",
    "level": "log",
    "text": "ready",
    "source": {
      "context": "main",
      "realm": "main"
    }
  }
}
```

## Response schema

Success:

```json
{
  "id": 1,
  "type": "success",
  "result": {}
}
```

Error:

```json
{
  "id": 1,
  "type": "error",
  "error": "unknown command",
  "message": "Unsupported method: xxx"
}
```

For JavaScript errors, include `stacktrace` when available:

```json
{
  "id": 3,
  "type": "error",
  "error": "javascript error",
  "message": "ReferenceError: foo is not defined",
  "stacktrace": "ReferenceError: foo is not defined\\n..."
}
```

| error | Use |
| --- | --- |
| `unknown command` | Unsupported method |
| `invalid argument` | Invalid params |
| `no such frame` | Context is not `main` |
| `javascript error` | JavaScript evaluation failed |
| `timeout` | Navigation or JavaScript timeout |
| `unknown error` | Failure such as a WKWebView load failure that does not fit the categories above |

## Request and response examples

### Status
```json
{
  "id": 1,
  "method": "session.status",
  "params": {}
}
```

```json
{
  "id": 1,
  "type": "success",
  "result": {
    "ready": true,
    "message": "SwiftScraper WKWebView BiDi bridge is ready"
  }
}
```

### Subscribe
```json
{
  "id": 2,
  "method": "session.subscribe",
  "params": {
    "events": [
      "log.entryAdded",
      "browsingContext.load",
      "browsingContext.domContentLoaded"
    ],
    "contexts": ["main"]
  }
}
```

### Navigate
```json
{
  "id": 3,
  "method": "browsingContext.navigate",
  "params": {
    "context": "main",
    "url": "https://example.com",
    "wait": "complete"
  }
}
```

### Preload script
```json
{
  "id": 4,
  "method": "script.addPreloadScript",
  "params": {
    "functionDeclaration": "() => { window.__swiftScraperInjected = true; }",
    "contexts": ["main"]
  }
}
```

```json
{
  "id": 5,
  "type": "success",
  "result": {
    "script": "preload-..."
  }
}
```

### Screenshot
```json
{
  "id": 6,
  "method": "browsingContext.captureScreenshot",
  "params": {
    "context": "main"
  }
}
```

### Viewport
```json
{
  "id": 7,
  "method": "browsingContext.setViewport",
  "params": {
    "context": "main",
    "viewport": {
      "width": 1280,
      "height": 720
    }
  }
}
```

### Cookies
```json
{
  "id": 8,
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

```json
{
  "id": 9,
  "method": "storage.getCookies",
  "params": {}
}
```

```json
{
  "id": 10,
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

### Evaluate
```json
{
  "id": 11,
  "method": "script.evaluate",
  "params": {
    "target": {
      "context": "main"
    },
    "expression": "document.title",
    "awaitPromise": false
  }
}
```

### HTML extraction
```json
{
  "id": 12,
  "method": "swiftScraper:scrape.getHTML",
  "params": {
    "context": "main"
  }
}
```

### Scraping wait
```json
{
  "id": 13,
  "method": "swiftScraper:scrape.waitForSelector",
  "params": {
    "context": "main",
    "selector": "article",
    "timeout": 10000,
    "polling": 250
  }
}
```

```json
{
  "id": 14,
  "method": "swiftScraper:scrape.waitForFunction",
  "params": {
    "context": "main",
    "expression": "document.querySelectorAll('article').length > 0",
    "timeout": 10000,
    "polling": 250
  }
}
```

### Scraping extraction
```json
{
  "id": 15,
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

Response:

```json
{
  "id": 15,
  "type": "success",
  "result": {
    "mode": "contentOnly",
    "format": "markdown",
    "data": "# Article title\\n\\n..."
  }
}
```

## Implementation notes
- The WebSocket server uses SwiftNIO (`NIOCore`, `NIOHTTP1`, `NIOWebSocket`, `NIOPosix`)
- Accept HTTP upgrades only at `/session`
- `BiDiDispatcher` operates on `BiDiWebViewHost` on MainActor
- The only browsing context currently supported is `main`
- Normalize remote values to `JSONValue`; responses include `result` plus the simple compatibility fields `type` and `value`
- `awaitPromise: true` uses `WKWebView.callAsyncJavaScript`
- Manage preload scripts by rebuilding the `WKUserContentController` user-script list
- Encode screenshots as PNG with `WKSnapshotConfiguration` and `NSBitmapImageRep`
- Use `WKWebsiteDataStore.httpCookieStore` for runtime cookies

## Constraints
- This is not fully compatible with Chrome or Firefox WebDriver BiDi endpoints
- Complete support for multiple browsing contexts, strict iframe management, and all realms is not implemented
- Network events, request interception, response body retrieval, and download control are unsupported
- Screenshots cover only the viewport; stitching the full scroll view into a full-page screenshot is unsupported
- `WKURLSchemeHandler` cannot directly capture ordinary `http` or `https` response bodies
- `--cookie-jar` is unsupported in long-running server mode because the save timing is ambiguous

## Security

The BiDi server exposes a remote JavaScript execution endpoint. If it binds to a public interface, treat it as an endpoint through which external clients can execute arbitrary JavaScript.

Recommendations:

- Use the default `--bidi-host 127.0.0.1`
- If remote exposure is required, add token authentication before using it
- Restrict allowed origins or target URLs when appropriate
- Do not run it with a sensitive browser profile

## Crawling policy

Users are responsible for following:

- The target site's terms of service
- `robots.txt` and other robots policies
- Rate limits
- Applicable laws and regulations

This tool is not intended to bypass access controls or bot protection.

## Possible extensions
- `browsingContext.create`
- Full-page screenshots
- Limited network event support
