# 11. WebDriver BiDi bridge

## 目的
外部プログラムから WebSocket / JSON で SwiftScraper の `WKWebView` を操作し、URL 遷移、JavaScript 実行、HTML / text 取得を行えるようにする。

この機能は WebDriver BiDi 風の scraping 用 bridge であり、WKWebView 自体を完全な WebDriver BiDi ブラウザにするものではない。

```text
external client
  -> WebSocket / JSON
SwiftNIO BiDi server
  -> BiDiDispatcher
  -> BiDiWebViewHost
  -> WKWebView
```

## 起動方法
既定 endpoint は `ws://127.0.0.1:9222/session`。

```bash
swift run swift-scraper -- \
  --bidi-server \
  --verbose
```

bind host / port を変える場合:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-host 127.0.0.1 \
  --bidi-port 9333
```

初期 URL をロードしてから待ち受ける場合:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --url https://example.com \
  --visibility hidden-window
```

## Puppeteer からの smoke test
Puppeteer の WebDriver BiDi 接続で bridge に接続できるかを確認する最小 probe:

```bash
npm install
swift run swift-scraper -- \
  --bidi-server \
  --verbose \
  --visibility hidden-window
```

別 shell で:

```bash
npm run puppeteer:bidi-p1
```

`puppeteer:bidi-p1` は script 内で `127.0.0.1` の一時 HTTP server と fixture HTML を起動し、`session.subscribe`、`browsingContext.navigate` の `wait`、`script.addPreloadScript` / `removePreloadScript`、`browsingContext.captureScreenshot`、`browsingContext.setViewport`、runtime cookie API、JavaScript error response、SwiftScraper extension scraping command を外部サイト依存なしで確認する。

実サイト scraping の probe:

```bash
npm run puppeteer:google
```

probe は `ws://127.0.0.1:9222/session` に `puppeteer-core` で接続し、Google を開いて検索 input に `Apple Swift` を入れ、検索を送信して検索結果リンクを抽出する。

Google の bot 検知を避けて別サイトで確認する場合は、Yahoo! JAPAN 用 probe も利用できる。

```bash
npm run puppeteer:yahoo
```

Yahoo! JAPAN probe は `https://www.yahoo.co.jp/` を開いて検索 input に `Apple Swift` を入れ、検索を送信して `search.yahoo.co.jp` の検索結果リンクを抽出する。

接続先や query を変える場合:

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

Google 側が bot 検知ページ（`/sorry`）を返した場合は、bridge / Puppeteer 接続自体は成功していても検索結果一覧は取得できない。その場合、probe は bot 検知 URL とページ本文の一部を出して失敗する。

Safari と同じ User-Agent に寄せる場合は、`User-Agent` header を指定する。BiDi server mode ではこの値を navigation request header だけでなく `WKWebView.customUserAgent` にも反映する。

```bash
SAFARI_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15'

swift run swift-scraper -- \
  --bidi-server \
  --verbose \
  --visibility visible-window \
  --header "User-Agent: $SAFARI_UA"
```

## 併用できる主なオプション
- `--url <url>`: 起動時に最初に開く URL
- `--cookie <spec>` / `--cookie-file <path>`: 起動時に Cookie を注入
- `--header <Name: Value>`: navigation request に HTTP header を追加。`User-Agent` は `WKWebView.customUserAgent` にも反映
- `--persistent-store`: 永続 `WKWebsiteDataStore` を使う
- `--visibility <mode>`: `windowless` / `hidden-window` / `visible-window`。`visible-window` は起動時に `SwiftScraper BiDi` window を通常ウィンドウとして前面化する。close ボタンでは server を止めず、window だけ非表示にする
- `--viewport <width>x<height>`: WebView サイズ
- `--load-timeout <seconds>`: navigation timeout
- `--js-timeout <seconds>`: JavaScript 実行 timeout

`visible-window` の表示を確認する場合は、初期 URL も指定すると `about:blank` ではなくページ内容が見える。

```bash
swift run swift-scraper -- \
  --bidi-server \
  --verbose \
  --visibility visible-window \
  --url https://www.yahoo.co.jp/
```

## 併用できないオプション
BiDi server は長時間起動する操作モードなので、通常の 1 shot scraping / batch / PDF 出力 / PDF リンクダウンロードとは分離している。

- `--pdf`
- `--download-pdfs`
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

## 対応 method

### WebDriver BiDi compatible methods

| method | 内容 |
| --- | --- |
| `session.status` | server の ready 状態を返す |
| `session.new` | Puppeteer 互換用の最小 session を作成した体裁の response を返す |
| `session.end` | compatibility no-op。client 互換用に success を返す |
| `session.subscribe` | client ごとの event subscription を登録する |
| `session.unsubscribe` | client ごとの event subscription を解除する |
| `browser.getUserContexts` | 単一 user context `default` を返す |
| `browser.close` | compatibility no-op。server process は終了しない |
| `browsingContext.getTree` | 単一 context `main` を返す |
| `browsingContext.navigate` | 指定 URL へ遷移する。`wait` は `none` / `interactive` / `complete` に対応 |
| `browsingContext.reload` | 現在 URL を再ロードする。`wait` は `none` / `interactive` / `complete` に対応 |
| `browsingContext.captureScreenshot` | 現在 viewport の PNG screenshot を base64 で返す |
| `browsingContext.setViewport` | runtime 中に `WKWebView` frame size を変更する |
| `script.evaluate` | `WKWebView.evaluateJavaScript` / `callAsyncJavaScript` で式を実行する |
| `script.callFunction` | 関数宣言と引数を page world で実行する |
| `script.addPreloadScript` | future document に document start script を追加する |
| `script.removePreloadScript` | 追加済み preload script を削除する |
| `storage.getCookies` | `WKHTTPCookieStore` から runtime cookie を取得する |
| `storage.setCookie` | runtime cookie を追加・更新する |
| `storage.deleteCookies` | name / domain / path filter に一致する runtime cookie を削除する |
| `emulation.setScreenOrientationOverride` | Puppeteer `page.setViewport` 互換用の compatibility no-op |

### SwiftScraper extension methods

正式名は WebDriver BiDi extension module 形式の `swiftScraper:scrape.*`。既存の `scrape.*` は短縮 alias として残している。

| method | 内容 |
| --- | --- |
| `swiftScraper:scrape.getHTML` | `document.documentElement.outerHTML` を返す |
| `swiftScraper:scrape.getText` | `document.body.innerText` を返す |
| `swiftScraper:scrape.waitForSelector` | selector が出現するまで polling する |
| `swiftScraper:scrape.waitForText` | document text に指定文字列が出現するまで polling する |
| `swiftScraper:scrape.waitForFunction` | JavaScript expression が truthy になるまで polling する |
| `swiftScraper:scrape.waitForDOMStable` | DOM snapshot が一定時間変化しなくなるまで待つ |
| `swiftScraper:scrape.autoScroll` | viewport 単位で scroll し、bottom と scrollHeight 安定を待つ |
| `swiftScraper:scrape.extract` | SwiftScraper の抽出 engine を server mode から実行する |
| `swiftScraper:scrape.getCookies` | `storage.getCookies` と同じ runtime cookie 取得 alias |
| `swiftScraper:scrape.setCookie` | `storage.setCookie` と同じ runtime cookie 設定 alias |
| `swiftScraper:scrape.deleteCookies` | `storage.deleteCookies` と同じ runtime cookie 削除 alias |

## 対応している仕様範囲

この bridge は WebDriver BiDi の scraping 用 subset と Puppeteer 接続に必要な最小互換を実装している。標準 BiDi browser としての完全互換は目的にしていない。

### Transport / session
- WebSocket endpoint は `/session` のみ。既定は `ws://127.0.0.1:9222/session`
- WebSocket text frame の JSON request / response に対応
- request は `id` 付き command を前提にする。`id` がない event-style command は受け付けない
- response は `type: "success"` / `type: "error"` を返す
- `session.status` で ready 状態を返す
- `session.new` は Puppeteer の pure WebDriver BiDi 接続初期化を通すための最小 capability を返す
- `session.subscribe` / `session.unsubscribe` は WebSocket client ごとに event subscription state を保持する
- `session.subscribe` は event 名だけでなく `log` / `browsingContext` のような module 名も簡易的に扱う
- `session.end` は compatibility no-op

### Browser / user context
- user context は `default` だけ
- `browser.getUserContexts` は `default` のみ返す
- `browser.close` は compatibility no-op。server process は終了しない

### Browsing context / navigation
- browsing context は `main` だけ
- `browsingContext.getTree` は `main` の単一 tree を返す
- `browsingContext.navigate` は `WKWebView.load` / `loadFileURL` で URL 遷移する
- `browsingContext.reload` は現在 URL を再ロードする
- `wait` は `none` / `interactive` / `complete` に対応する。未指定時は既存挙動維持のため `complete`
- `interactive` は document start の user script で `DOMContentLoaded` を hook した近似実装
- `complete` は `WKNavigationDelegate.webView(_:didFinish:)` を待つ
- navigation に対して簡易 `navigation` id を返す
- navigation 中は `browsingContext.navigationStarted` を subscribed client に送る
- navigation の DOMContentLoaded 相当時は `browsingContext.domContentLoaded` を subscribed client に送る
- navigation 完了時は `browsingContext.load` を subscribed client に送る
- navigation 失敗時は `browsingContext.navigationFailed` を subscribed client に送る
- `browsingContext.captureScreenshot` は現在 viewport の PNG を `WKWebView.takeSnapshot` で取得する。full page screenshot は未対応
- `browsingContext.setViewport` は `WKWebView` frame と visible window の content size を更新する

### Script
- `script.evaluate` は page world で式を評価する
- `awaitPromise: true` は `WKWebView.callAsyncJavaScript` を使う
- `script.callFunction` は `functionDeclaration` と `arguments` を page world で実行する
- `script.addPreloadScript` は `functionDeclaration` を future document の document start で実行する
- `script.removePreloadScript` は script id に一致する preload script を削除する
- preload script は既存 document には retroactive に実行しない
- `target.context` は `main` のみ対応
- remote value は `null` / `boolean` / `number` / `string` / `array` / `object` に正規化する
- object remote value は BiDi deserializer 互換の property tuple 配列で返す

### Log event
- document start の user script で `console.log` / `info` / `warn` / `error` / `debug` を hook する
- console 出力を `log.entryAdded` として subscribed client に送る

### 独自 scraping command
- `swiftScraper:scrape.*` は SwiftScraper 固有の BiDi extension module。`scrape.*` は後方互換の alias
- `swiftScraper:scrape.getHTML` は `document.documentElement.outerHTML` を返す
- `swiftScraper:scrape.getText` は `document.body.innerText` を返す
- `swiftScraper:scrape.waitForSelector` / `waitForText` / `waitForFunction` は `timeout` / `polling` を milliseconds で受け取る
- `swiftScraper:scrape.waitForDOMStable` は `stableTime` / `timeout` / `polling` を milliseconds で受け取る
- `swiftScraper:scrape.autoScroll` は既存 CLI の `--auto-scroll` と同じ scroll probe を使う
- `swiftScraper:scrape.extract` は `mode` に `outerHTML` / `bodyText` / `selectorInnerHTML` / `contentOnly` / `structureInspection`、`format` に `plain` / `markdown` を指定できる
- `swiftScraper:scrape.extract` は `prettyPrint`、`extractImages`、`imageFilter`、`imageScoreThreshold`、`imageIncludeMaybe`、`imageDebug` を受け取る
- `swiftScraper:scrape.getCookies` / `setCookie` / `deleteCookies` は `storage.*` cookie command の alias

### 起動時設定
- `--url` で初期 URL を load できる
- `--cookie` / `--cookie-file` で起動時 Cookie を注入できる
- `--header` で navigation request header を付与できる
- `User-Agent` header は `WKWebView.customUserAgent` にも反映する
- `--persistent-store` で永続 `WKWebsiteDataStore` を使える
- `--viewport` で WebView frame size を指定できる
- `--visibility visible-window` で `WKWebView` を通常 window として表示できる

### Storage / Cookie
- `storage.getCookies` は `WKHTTPCookieStore.getAllCookies` の結果を返す
- `storage.setCookie` は `cookie` object または flat params から `HTTPCookie` を生成して設定する
- `storage.deleteCookies` は `filter` object または flat params の `name` / `domain` / `path` に完全一致する cookie を削除する
- partitioned cookie / storage key は未対応

### Puppeteer 互換の現状
- `puppeteer.connect({ browserWSEndpoint, protocol: "webDriverBiDi" })` の接続初期化に必要な最小 command に対応している
- `page.evaluate` / `page.evaluateHandle` 相当の DOM 操作を中心にした smoke test は動作する
- `scripts/puppeteer-yahoo-search.mjs` は Yahoo! JAPAN で検索結果抽出まで確認済み
- Puppeteer の高レベル API 全般を保証するものではない。`page.click` / `page.keyboard` / selector polling などは未対応 BiDi command に到達する可能性があるため、現状の probe は `page.evaluate` 中心で実装している

## 未対応仕様

### Session / browser
- 複数 session の管理
- event subscription の厳密な spec conformance
- `browser.createUserContext`
- `browser.removeUserContext`
- `browser.close` による process 終了

### Browsing context
- 複数 top-level browsing context
- `browsingContext.create`
- `browsingContext.close`
- `browsingContext.activate`
- `browsingContext.print`
- `browsingContext.traverseHistory`
- full page screenshot
- iframe / child context の厳密な tree 管理
- `browsingContext.contextCreated` / `contextDestroyed` の完全な lifecycle event
- fragment navigation / history update / navigation committed の厳密な event
- prompt / dialog handling
- download 制御

### Script / realm
- 複数 realm
- sandbox realm
- iframe realm
- worker / shared worker / service worker realm
- preload script の sandbox / realm / strict context scope
- `script.disown`
- remote object handle の lifetime 管理
- DOM node remote value / shared reference
- exception details の完全な BiDi 形式

### Input
- `input.performActions`
- `input.releaseActions`
- pointer / keyboard / wheel action
- file dialog event
- file upload 制御

### Network
- `network.beforeRequestSent`
- `network.responseStarted`
- `network.responseCompleted`
- `network.fetchError`
- request interception
- response body 取得
- data collector
- cache behavior 制御
- auth challenge handling
- WebSocket / EventSource event

### Storage / Cookie
- partitioned cookie / storage key
- cookie sameSite / priority / sourcePort などの詳細属性
- `--cookie-jar` による server mode の保存

### Permissions / emulation
- `permissions.setPermission`
- geolocation override
- timezone override
- screen orientation override
- touch override
- user agent override command
- device metrics / media emulation

### CDP / browser-specific extension
- CDP over BiDi
- `goog:cdp.*`
- `goog:cdp.resolveRealm`
- Chrome / Firefox 固有 capability

### 仕様上の注意
- この bridge は `WKWebView` を外部から操作するための scraping bridge であり、WebDriver BiDi conformance target ではない
- 未対応 command は `unknown command` を返す
- context が `main` 以外の場合は `no such frame` を返す
- JavaScript 実行エラーは `javascript error` として返す。JS 側 wrapper で取得できる範囲では `message` と `stacktrace` を含める
- navigation / JS timeout は `timeout` を返す
- `WKURLSchemeHandler` の制約により、通常の `http` / `https` response body を network layer で直接捕捉しない

## Event
ページ内の `console.log` / `info` / `warn` / `error` / `debug` を document start の user script で hook し、`session.subscribe` 済みの WebSocket client へ `log.entryAdded` として送る。

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

success:

```json
{
  "id": 1,
  "type": "success",
  "result": {}
}
```

error:

```json
{
  "id": 1,
  "type": "error",
  "error": "unknown command",
  "message": "Unsupported method: xxx"
}
```

JavaScript error では、取得できる場合に `stacktrace` を追加する:

```json
{
  "id": 3,
  "type": "error",
  "error": "javascript error",
  "message": "ReferenceError: foo is not defined",
  "stacktrace": "ReferenceError: foo is not defined\n..."
}
```

| error | 用途 |
| --- | --- |
| `unknown command` | 未対応 method |
| `invalid argument` | params 不正 |
| `no such frame` | context が `main` 以外 |
| `javascript error` | JS 評価失敗 |
| `timeout` | navigation / JS timeout |
| `unknown error` | WKWebView load failure など、上記に分類できない失敗 |

## Request / response 例

### status
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

### subscribe
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

### navigate
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

### preload script
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

### screenshot
```json
{
  "id": 6,
  "method": "browsingContext.captureScreenshot",
  "params": {
    "context": "main"
  }
}
```

### viewport
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

### cookies
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

### evaluate
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

### HTML 取得
```json
{
  "id": 12,
  "method": "swiftScraper:scrape.getHTML",
  "params": {
    "context": "main"
  }
}
```

### scraping wait
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

### scraping extract
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

response:

```json
{
  "id": 15,
  "type": "success",
  "result": {
    "mode": "contentOnly",
    "format": "markdown",
    "data": "# Article title\n\n..."
  }
}
```

## 実装メモ
- WebSocket server は SwiftNIO (`NIOCore`, `NIOHTTP1`, `NIOWebSocket`, `NIOPosix`) を使う
- HTTP upgrade は `/session` のみ受け付ける
- `BiDiDispatcher` は MainActor 上で `BiDiWebViewHost` を操作する
- browsing context は現時点で `main` だけ
- remote value は `JSONValue` に正規化し、response には `result` と簡易互換の `type` / `value` を含める
- `awaitPromise: true` は `WKWebView.callAsyncJavaScript` を使う
- preload script は `WKUserContentController` の user script list を再構築して管理する
- screenshot は `WKSnapshotConfiguration` と `NSBitmapImageRep` による PNG encode を使う
- runtime cookie は `WKWebsiteDataStore.httpCookieStore` を使う

## 制約
- Chrome / Firefox の WebDriver BiDi endpoint と完全互換ではない
- 複数 browsing context、iframe の厳密管理、realm の完全な実装はない
- network event、request interception、response body 取得、download 制御は未対応
- screenshot は viewport のみ。scroll view 全体を stitch する full page screenshot は未対応
- `WKURLSchemeHandler` では通常の `http` / `https` response body を直接捕捉できない
- `--cookie-jar` は長時間 server mode では保存タイミングが曖昧になるため未対応

## Security

BiDi server は remote JavaScript execution endpoint を公開する。public interface へ bind する場合は、外部から任意 JavaScript を実行できる前提で扱う。

推奨:

- 既定どおり `--bidi-host 127.0.0.1` を使う
- remote exposure が必要な場合は token authentication を追加してから使う
- 必要に応じて allowed origin / target URL を制限する
- sensitive な browser profile では実行しない

## Crawling policy

利用者は以下を遵守する責任がある。

- 対象サイトの terms of service
- robots.txt / robots policy
- rate limit
- 適用される法令・規制

この tool は access control や bot protection の回避を目的にしない。

## 拡張候補
- `browsingContext.create`
- full page screenshot
- network event の限定的な実装
