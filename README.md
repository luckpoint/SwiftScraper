# SwiftScraper

macOS 標準の `WKWebView` を使って、JavaScript 実行後のページ内容を取得する Swift 製 CLI です。  
単純な `URLSession` 取得では取り切れない動的ページを、Cookie 注入、描画待機、本文抽出、Markdown 変換、batch 実行付きで扱います。

## 特徴
- `WKWebView` ベースで JS レンダリング後の DOM を取得
- `--cookie` / `--cookie-file` / `--cookie-jar` でセッション状態を注入・保存
- `--header` でカスタム HTTP ヘッダーを追加（Accept-Language 等）
- 固定待機、自動スクロール、セレクタ待機、テキスト待機、DOM 安定待機を組み合わせ可能
- HTML 全体、`body` テキスト、特定要素、本文候補、構造確認レポートを抽出可能
- HTML の pretty print と Markdown 変換に対応
- 画像候補の特徴量を JS で集め、Swift の heuristic でロゴや UI 画像を落とせる
- `sitemap.xml` または URL ファイルから複数ページを batch 実行可能
- PDF リンク集ページから `.pdf` リンクを抽出し、サイト別フォルダに保存可能
- SwiftNIO の WebSocket サーバで WKWebView を操作する WebDriver BiDi 風 bridge を起動可能
- `windowless` / `hidden-window` / `visible-window` で露出度を切り替え可能

## 動作要件
- macOS 13 以上
- Swift 6.0

`WKWebView` と AppKit を使うため、macOS 専用です。  
完全な headless ブラウザではなく、ユーザー露出を抑えた実行を目指す設計です。

## ビルド
```bash
swift build
```

release build:

```bash
swift build -c release
```

生成バイナリ:

```bash
.build/release/swift-scraper
```

### インストール
Release ビルドを実行し、`~/.local/bin/swift-scraper` に配置する:

```bash
./scripts/install.sh
```

インストール先を変更する場合は `BIN_DIR` を指定する:

```bash
BIN_DIR="$HOME/bin" ./scripts/install.sh
```

## 実行方法
### 基本
```bash
swift run swift-scraper -- https://example.com
```

`swift run` 経由では `--` を入れて、CLI オプションをその後ろに渡します。

### 主なオプション
```text
--bidi-server                 WKWebView BiDi bridge server を起動
--bidi-host <host>            BiDi server の bind host。既定 127.0.0.1
--bidi-port <port>            BiDi server の bind port。既定 9222
--cookie <spec>                Cookie を 1 件追加
--cookie-file <path>           Cookie JSON を読み込む
--cookie-jar <path>            CookieJar JSON を読み込み、実行後に保存する
--header <Name: Value>         HTTP ヘッダーを追加。複数指定可
--persistent-store             永続 DataStore を使う
--visibility <mode>            windowless | hidden-window | visible-window
--viewport <width>x<height>    WebView サイズ。既定 1440x900
--wait-delay <seconds>         didFinish 後の固定待機
--auto-scroll                  lazy load 補助のため下方向へ自動スクロール
--wait-selector <css>          CSS セレクタ出現待機。複数指定可
--wait-text <text>             テキスト出現待機。複数指定可
--poll-interval <seconds>      条件待機のポーリング間隔。既定 0.5
--dom-stable-delay <seconds>   DOM が安定したとみなす時間。既定 0.5
--load-timeout <seconds>       ロード段階タイムアウト。既定 30
--wait-timeout <seconds>       描画待機タイムアウト。既定 15
--js-timeout <seconds>         JavaScript 実行タイムアウト。既定 10
--download-pdfs <directory>    ページ内の PDF リンクを保存
--download-linked-pdfs <dir>   通常抽出と同時にページ内の PDF リンクを保存
--overwrite-pdfs               既存 PDF を連番回避せず同名で上書き
--output <path>                標準出力ではなくファイルへ保存
--body-text                    document.body.innerText を抽出
--selector-inner-html <css>    特定要素の innerHTML を抽出
--content-only                 本文候補の HTML を抽出
--inspect-structure            本文候補とランドマーク情報だけを確認
--markdown                     HTML 系抽出結果を Markdown に変換
--extract-images               画像 heuristic を適用して HTML 系出力の画像を絞り込む
--image-filter <mode>          all | article-only
--image-score-threshold <0-1>  keep 判定の閾値。既定 0.65
--image-include-maybe          maybe 判定の画像も出力に残す
--image-debug                  画像スコアと理由を stderr に JSON で出す
--pretty-print                 HTML 系出力を整形
--verbose                      stderr に進行ログを出す
--sitemap                      sitemap.xml をたどって batch 実行
--url-file <path>              URL 一覧ファイルを使って batch 実行
--concurrency <count>          batch 並列数。既定 4
```

## 使い方
### 1. HTML 全体を取得
```bash
swift run swift-scraper -- https://example.com --output out/page.html
```

### 2. 本文候補だけを Markdown 化
```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --output out/article.md
```

### 3. 描画待機を入れる
```bash
swift run swift-scraper -- \
  https://example.com/app \
  --auto-scroll \
  --wait-selector "#app" \
  --wait-text "Loaded" \
  --wait-timeout 20 \
  --dom-stable-delay 1.0
```

### 4. 本文画像だけを残す
```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --extract-images \
  --image-filter article-only \
  --image-debug
```

`--extract-images` を付けると、HTML / Markdown 化の前に画像 heuristic を適用し、`drop` 判定の画像を出力から除去します。`--image-debug` はスコアと理由を stderr へ JSON で出します。

### 5. PDF リンク集から PDF を保存する
```bash
swift run swift-scraper -- \
  https://www.okta.com/legal/trustandcompliance/ \
  --download-pdfs downloads \
  --auto-scroll
```

PDF は `downloads/<host>/<source-path>/` に保存されます。上の例では `downloads/www.okta.com/legal/trustandcompliance/` です。

ファイル名はリンクテキストと元ファイル名から作ります。リンクテキストは空白を正規化し、30文字に切り詰めます。リンクテキストが空なら元ファイル名だけを使います。

```text
Okta Model Card Governance Ana-okta-model-card-governance-analyzer-2026-02-13.pdf
```

同名ファイルが既にある場合、通常は `-2`、`-3` のように連番を付けて保存します。既存 PDF を同名で置き換えたい場合は `--overwrite-pdfs` を指定します。同一実行内に同じファイル名になるリンクが複数ある場合は、上書き指定時でも 2 件目以降に連番を付けます。

実行結果は stdout に JSON で出力され、保存先、成功件数、失敗件数、各 PDF の URL と保存パスを確認できます。`--cookie` / `--cookie-file` / `--cookie-jar` / `--header` / 待機系オプションは PDF リンク抽出にも利用できます。

PDF 本体のダウンロードは `URLSession` で行います。Cookie は描画後の `WKWebsiteDataStore.httpCookieStore` から取得し、PDF URL に合うものを `Cookie` ヘッダーへ反映します。`User-Agent` は `--header 'User-Agent: ...'` があればその値を優先し、未指定の場合は WKWebView 内の `navigator.userAgent` を取得して PDF ダウンロード request に設定します。

`--download-pdfs` は `--sitemap` / `--url-file` と併用できます。各ページを描画して PDF リンクだけを保存し、batch の PDF ダウンロード結果 JSON を stdout へ出力します。

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --download-pdfs downloads \
  --concurrency 4
```

通常の抽出結果も欲しい場合は `--download-linked-pdfs <dir>` を使います。通常 scrape の stdout / `--output` はそのまま維持し、PDF ダウンロード結果は `<dir>/pdf-downloads.json` に保存します。

```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/docs.md
```

### 6. Cookie を直接注入する
```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --cookie 'name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true'
```

### 7. Cookie JSON を使う
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

### 8. CookieJar JSON を使う
`--cookie-jar` は指定ファイルが存在すればロード前に Cookie を注入し、実行後に WebKit の CookieStore に残っている Cookie を同じJSONファイルへ保存します。ファイルが存在しない場合は空の CookieJar として扱い、実行後に作成します。

```bash
swift run swift-scraper -- \
  https://example.com/dashboard \
  --cookie-jar cookies.json
```

CookieJar の形式は `--cookie-file` と同じです。保存時は JSON array として出力します。`--sitemap` / `--url-file` の batch 実行では `--cookie-jar` は使用できません。

### 9. カスタム HTTP ヘッダーを送る
```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --header 'Accept-Language: en,en-US;q=0.9' \
  --header 'X-Custom-Header: value'
```

ロケール検出でリダイレクトされるサイトに対して、`Accept-Language` ヘッダーで英語版を強制取得する場合などに使います。

### 10. sitemap から batch 実行する
```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --content-only \
  --markdown \
  --concurrency 8 \
  --output out/sitemap-batch.json
```

### 11. URL ファイルから batch 実行する
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

### 12. WebDriver BiDi bridge を起動する
`--bidi-server` は SwiftNIO の WebSocket サーバを起動し、外部プログラムから JSON コマンドで同一プロセス内の `WKWebView` を操作できるようにします。endpoint は `ws://127.0.0.1:9222/session` です。

```bash
swift run swift-scraper -- \
  --bidi-server \
  --bidi-port 9222 \
  --verbose
```

初期 URL を指定する場合:

```bash
swift run swift-scraper -- \
  --bidi-server \
  --url https://example.com \
  --visibility hidden-window
```

対応する主な method:
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

P0/P1 と SwiftScraper scraping extension を外部サイト依存なしで確認する場合:

```bash
npm run puppeteer:bidi-p1
```

これは WKWebView を WebSocket 経由で操作する scraping 用 bridge です。Chrome や Firefox の WebDriver BiDi と完全互換のブラウザ実装ではありません。詳細は [11. WebDriver BiDi bridge](docs/11-webdriver-bidi-bridge.md) を参照してください。

## 抽出モード
| モード | 説明 |
| --- | --- |
| 既定 | `document.documentElement.outerHTML` |
| `--body-text` | `document.body.innerText` |
| `--selector-inner-html <css>` | 一致要素の `innerHTML` |
| `--content-only` | 本文候補だけを抽出 |
| `--inspect-structure` | 本文候補、ランドマーク数、除去情報をテキストレポート化 |

制約:
- `--markdown` は HTML を返す抽出モードでだけ使えます
- `--extract-images` は HTML を返す抽出モードでだけ使えます
- `--markdown` と `--pretty-print` は同時指定できません
- `--selector-inner-html` は対象要素が見つからないとエラーになります
- `--auto-scroll` は文書全体のスクロールにだけ効き、内部スクロールコンテナには別対応が必要な場合があります

## batch 出力
batch 実行時の最終出力は JSON です。各ページの成功 / 失敗が `pages[]` に入ります。

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
      "error": "ページロードに失敗しました"
    }
  ]
}
```

終了コード:
- `0`: 成功
- `1`: 実行時失敗、または batch 内に失敗ページあり
- `2`: CLI 引数エラー

## ドキュメント
- [01. ページロード](docs/01-page-loading.md)
- [02. Cookie 注入](docs/02-cookie-injection.md)
- [03. レンダリング待機](docs/03-rendering-wait.md)
- [04. HTML / DOM 取得](docs/04-html-dom-extraction.md)
- [05. ユーザー露出の抑制](docs/05-user-visibility-control.md)
- [06. 安定性とタイムアウト制御](docs/06-stability-and-timeout.md)
- [07. デバッグ運用](docs/07-debug-operability.md)
- [08. Batch 実行](docs/08-batch-processing.md)
- [09. 画像抽出と heuristic](docs/09-image-extraction.md)
- [10. PDF 生成](docs/10-pdf-generation.md)
- [11. WebDriver BiDi bridge](docs/11-webdriver-bidi-bridge.md)
- [12. PDF リンクダウンロード](docs/12-pdf-link-download.md)
- [13. Knowledge Base 向け改善ロードマップ](docs/13-knowledge-base-roadmap.md)
- [14. 検索結果からの収集](docs/14-search-discovery.md)
- [15. Knowledge Base ソース成果物仕様](docs/15-kb-source-spec.md)

## 制約
- macOS 専用です
- gzip 圧縮された sitemap (`.xml.gz`) は URL 判定のみ対応で、中身の展開は未対応です
- `windowless` / `hidden-window` は露出を抑えるためのモードで、完全 headless を保証するものではありません
- 画像 heuristic の初期実装はページ単位判定までです。batch 頻度補正やドメイン別 blacklist は未実装です
- `--download-pdfs` / `--download-linked-pdfs` は `href` の path が `.pdf` で終わるリンクだけを対象にします。`.pdf` で終わらない download endpoint 対応は将来候補で、対応時期は未決定です
- WebDriver BiDi bridge は scraping 用 subset であり、WebDriver BiDi 仕様の完全実装ではありません
