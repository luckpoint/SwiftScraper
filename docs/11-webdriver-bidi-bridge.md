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
BiDi server は長時間起動する操作モードなので、通常の 1 shot scraping / batch / PDF 出力とは分離している。

- `--pdf`
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

| method | 内容 |
| --- | --- |
| `session.status` | server の ready 状態を返す |
| `session.new` | Puppeteer 互換用の最小 session を作成した体裁の response を返す |
| `session.end` | no-op。client 互換用に success を返す |
| `session.subscribe` | no-op。client 互換用に success を返す |
| `session.unsubscribe` | no-op。client 互換用に success を返す |
| `browser.getUserContexts` | 単一 user context `default` を返す |
| `browser.close` | no-op。client 互換用に success を返す |
| `browsingContext.getTree` | 単一 context `main` を返す |
| `browsingContext.navigate` | 指定 URL へ遷移する |
| `browsingContext.reload` | 現在 URL を再ロードする |
| `script.evaluate` | `WKWebView.evaluateJavaScript` / `callAsyncJavaScript` で式を実行する |
| `script.callFunction` | 関数宣言と引数を page world で実行する |
| `scrape.getHTML` | `document.documentElement.outerHTML` を返す独自 command |
| `scrape.getText` | `document.body.innerText` を返す独自 command |

## 対応している仕様範囲

この bridge は WebDriver BiDi の scraping 用 subset と Puppeteer 接続に必要な最小互換を実装している。標準 BiDi browser としての完全互換は目的にしていない。

### Transport / session
- WebSocket endpoint は `/session` のみ。既定は `ws://127.0.0.1:9222/session`
- WebSocket text frame の JSON request / response に対応
- request は `id` 付き command を前提にする。`id` がない event-style command は受け付けない
- response は `type: "success"` / `type: "error"` を返す
- `session.status` で ready 状態を返す
- `session.new` は Puppeteer の pure WebDriver BiDi 接続初期化を通すための最小 capability を返す
- `session.subscribe` / `session.unsubscribe` / `session.end` は no-op

### Browser / user context
- user context は `default` だけ
- `browser.getUserContexts` は `default` のみ返す
- `browser.close` は no-op。server process は終了しない

### Browsing context / navigation
- browsing context は `main` だけ
- `browsingContext.getTree` は `main` の単一 tree を返す
- `browsingContext.navigate` は `WKWebView.load` / `loadFileURL` で URL 遷移する
- `browsingContext.reload` は現在 URL を再ロードする
- navigation に対して簡易 `navigation` id を返す
- navigation 中は `browsingContext.navigationStarted` を broadcast する
- navigation 完了時は `browsingContext.domContentLoaded` と `browsingContext.load` を broadcast する
- navigation 失敗時は `browsingContext.navigationFailed` を broadcast する

### Script
- `script.evaluate` は page world で式を評価する
- `awaitPromise: true` は `WKWebView.callAsyncJavaScript` を使う
- `script.callFunction` は `functionDeclaration` と `arguments` を page world で実行する
- `target.context` は `main` のみ対応
- remote value は `null` / `boolean` / `number` / `string` / `array` / `object` に正規化する
- object remote value は BiDi deserializer 互換の property tuple 配列で返す

### Log event
- document start の user script で `console.log` / `info` / `warn` / `error` / `debug` を hook する
- console 出力を `log.entryAdded` として接続中 client に broadcast する

### 独自 scraping command
- `scrape.getHTML` は `document.documentElement.outerHTML` を返す
- `scrape.getText` は `document.body.innerText` を返す

### 起動時設定
- `--url` で初期 URL を load できる
- `--cookie` / `--cookie-file` で起動時 Cookie を注入できる
- `--header` で navigation request header を付与できる
- `User-Agent` header は `WKWebView.customUserAgent` にも反映する
- `--persistent-store` で永続 `WKWebsiteDataStore` を使える
- `--viewport` で WebView frame size を指定できる
- `--visibility visible-window` で `WKWebView` を通常 window として表示できる

### Puppeteer 互換の現状
- `puppeteer.connect({ browserWSEndpoint, protocol: "webDriverBiDi" })` の接続初期化に必要な最小 command に対応している
- `page.evaluate` / `page.evaluateHandle` 相当の DOM 操作を中心にした smoke test は動作する
- `scripts/puppeteer-yahoo-search.mjs` は Yahoo! JAPAN で検索結果抽出まで確認済み
- Puppeteer の高レベル API 全般を保証するものではない。`page.click` / `page.keyboard` / selector polling などは未対応 BiDi command に到達する可能性があるため、現状の probe は `page.evaluate` 中心で実装している

## 未対応仕様

### Session / browser
- 複数 session の管理
- session ごとの event subscription state / event filter
- `session.subscribe` の厳密な module / context filter
- `browser.createUserContext`
- `browser.removeUserContext`
- `browser.close` による process 終了

### Browsing context
- 複数 top-level browsing context
- `browsingContext.create`
- `browsingContext.close`
- `browsingContext.activate`
- `browsingContext.captureScreenshot`
- `browsingContext.print`
- `browsingContext.traverseHistory`
- `browsingContext.setViewport`
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
- `script.addPreloadScript`
- `script.removePreloadScript`
- `script.disown`
- remote object handle の lifetime 管理
- DOM node remote value / shared reference
- exception details / stack trace の完全な BiDi 形式

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
- runtime 中の `storage.getCookies`
- runtime 中の `storage.setCookie`
- cookie delete
- partitioned cookie / storage key
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
- JavaScript 実行エラーは簡易的に `javascript error` として返す
- `WKURLSchemeHandler` の制約により、通常の `http` / `https` response body を network layer で直接捕捉しない

## Event
ページ内の `console.log` / `info` / `warn` / `error` / `debug` を document start の user script で hook し、接続中の WebSocket client へ `log.entryAdded` として broadcast する。

```json
{
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

### navigate
```json
{
  "id": 2,
  "method": "browsingContext.navigate",
  "params": {
    "context": "main",
    "url": "https://example.com"
  }
}
```

### evaluate
```json
{
  "id": 3,
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
  "id": 4,
  "method": "scrape.getHTML",
  "params": {
    "context": "main"
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

## 制約
- Chrome / Firefox の WebDriver BiDi endpoint と完全互換ではない
- 複数 browsing context、iframe の厳密管理、realm の完全な実装はない
- network event、request interception、response body 取得、download 制御は未対応
- `WKURLSchemeHandler` では通常の `http` / `https` response body を直接捕捉できない
- `--cookie-jar` は長時間 server mode では保存タイミングが曖昧になるため未対応

## 拡張候補
- `browsingContext.captureScreenshot`
- `browsingContext.create`
- `script.addPreloadScript`
- network event の限定的な実装
- explicit subscribe state による event filter
