# 12. PDF リンクダウンロード

## 目的
PDF リンク集ページや通常のスクレイピング対象ページを `WKWebView` で描画し、描画済み DOM 内の `.pdf` リンクを抽出してローカルへ保存する。

PDF だけを保存する専用モードと、通常 scrape と同時に PDF も保存する sidecar モードがある。

| モード | 用途 | PDF 結果 |
| --- | --- | --- |
| `--download-pdfs <dir>` | PDF リンク集から PDF だけを保存する | stdout の JSON |
| `--download-linked-pdfs <dir>` | 通常 scrape を行いながら、ページ内 PDF も保存する | `<dir>/pdf-downloads.json` |

## 例
単一ページの PDF リンク集を保存する:

```bash
swift run swift-scraper -- \
  https://www.okta.com/legal/trustandcompliance/ \
  --download-pdfs downloads \
  --auto-scroll
```

sitemap で複数ページをたどり、各ページ内の PDF だけを保存する:

```bash
swift run swift-scraper -- \
  https://example.com \
  --sitemap \
  --download-pdfs downloads \
  --concurrency 4
```

通常 scrape と同時に PDF も保存する:

```bash
swift run swift-scraper -- \
  https://example.com/docs \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/docs.md
```

URL ファイルの batch scrape と同時に PDF も保存する:

```bash
swift run swift-scraper -- \
  --url-file urls.txt \
  --content-only \
  --markdown \
  --download-linked-pdfs downloads \
  --output out/pages.json
```

## 入力
共通で利用できるページロード補助オプション:

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

`--download-pdfs` は `--sitemap` / `--url-file` / `--concurrency` と併用できる。`--concurrency` は batch 入力と一緒に指定した場合だけ有効。

`--download-linked-pdfs` は通常 scrape の追加オプションなので、`--content-only`、`--markdown`、`--output`、`--sitemap`、`--url-file` などの通常 scrape オプションと併用できる。

`--cookie-jar` は単一ページ実行では利用できるが、`--sitemap` / `--url-file` の batch 実行では利用できない。
ブラウザ Cookie は macOS の Chrome/Firefox のみ対応し、`--cookie` / `--cookie-file` の明示 Cookie が優先される。`--browser-cookies` と `--cookie-jar` は併用できない。

## 保存先
PDF は指定 root directory の下に、取得元ページの host と path を反映したディレクトリを作って保存する。

```text
downloads/
  www.okta.com/
    legal/
      trustandcompliance/
        <file>.pdf
```

`https://www.okta.com/legal/trustandcompliance/` から抽出した PDF は、`downloads/www.okta.com/legal/trustandcompliance/` に保存される。

複数ページ実行ではページごとに source path が分かれるため、どのサイト・どのページから保存した PDF かをフォルダ構成から確認できる。

## ファイル名
ファイル名は次の規則で作る。

1. PDF URL の最後の path component を元ファイル名として使う
2. リンクテキストがある場合は `<リンクテキスト>-<元ファイル名>.pdf`
3. リンクテキストは空白を正規化し、30文字で切り詰める
4. リンクテキストが空の場合は元ファイル名だけを使う
5. `/`、`\`、`:`、制御文字は `_` に置換する
6. 同名ファイルがある場合は `-2`、`-3` のように連番を付ける

例:

```text
Okta Model Card Governance Ana-okta-model-card-governance-analyzer-2026-02-13.pdf
report.pdf
report-2.pdf
```

## 処理概要
1. 通常のスクレイピングと同じ `WKWebView` で対象ページをロードする
2. Cookie、header、表示モード、viewport、待機オプションを適用する
3. 描画待機後、`document.querySelectorAll('a[href]')` からリンクを列挙する
4. `http:` / `https:` / `file:` の URL のうち、path が `.pdf` で終わるものだけを対象にする
5. URL fragment を除去し、重複 URL を除外する
6. `navigator.userAgent` から WKWebView の実 User-Agent を取得する
7. WebKit の CookieStore に残っている Cookie を PDF ダウンロード request に反映する
8. `URLSession` で PDF を取得し、取得元ページ別ディレクトリに保存する
9. `--download-pdfs` は stdout に JSON を出力し、`--download-linked-pdfs` は `<dir>/pdf-downloads.json` に manifest を保存する

`--download-linked-pdfs` ではページロードを二重に行わない。通常の抽出処理と同じ `WKWebView` 実行の中で PDF リンクも収集し、その後 PDF を保存する。

## User-Agent と Cookie
PDF リンクの抽出は WKWebView の描画済み DOM から行い、PDF 本体の取得は `URLSession` で行う。

`URLSession` の PDF download request には次の header を設定する。

- `--header` で指定された任意の header
- `--header 'User-Agent: ...'` がある場合は、その User-Agent
- `User-Agent` が未指定の場合は、WKWebView 内で取得した `navigator.userAgent`
- WebKit の `WKWebsiteDataStore.httpCookieStore` から取得した Cookie のうち、PDF URL の domain / path / secure / expires 条件に合う Cookie

Cookie は `Cookie` header として設定する。ただし `--header 'Cookie: ...'` が明示されている場合は、その値を優先し、自動生成した Cookie header は上書きしない。

このため、ログイン後やロケール判定後に WebKit CookieStore に入った Cookie は PDF ダウンロードにも引き継がれる。一方、`URLSession` は WebKit と同じブラウザ download 機構ではないため、同等の header / Cookie を明示的に再構成している。

## 出力 JSON
`--download-pdfs` の単一ページ実行では、成功・失敗を含む全 PDF の結果を stdout に出力する。

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

`--download-pdfs` の batch 実行と `--download-linked-pdfs` の manifest では、ページ単位の結果を含む JSON を出力する。

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

終了コード:

- `0`: ページ取得と PDF ダウンロードが成功、または PDF リンクが 0 件
- `1`: ページ取得に失敗、保存先作成に失敗、または PDF の一部/全部の保存に失敗
- `2`: CLI 引数エラー

`--download-linked-pdfs` では通常 scrape のページ失敗、または PDF ダウンロード失敗のどちらかがあれば終了コード 1 になる。通常 scrape の出力先と PDF manifest は分離される。

## 併用できないオプション
`--download-pdfs` は PDF 専用モードなので、通常の抽出出力とは分離している。

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

`--download-linked-pdfs` は通常 scrape の追加オプションだが、次のモードとは併用できない。

- `--pdf`
- `--bidi-server`
- `--download-pdfs`

## 制約
- `href` の path が `.pdf` で終わるリンクだけを対象にする。リダイレクト先が PDF になる download endpoint は対象外。
- PDF の `Content-Type` は検証しない。HTTP status が 2xx なら保存する。
- BiDi server の download 制御ではなく、CLI の 1 shot / batch mode として実装している。

## 将来の対応候補
`.pdf` で終わらない download endpoint から PDF が返るサイトへの対応は、将来の候補として残す。対応時期は未決定で、必要が出た時点で検討する。

全リンクに対して `HEAD` / `GET` を実行すると負荷と時間が大きくなりやすいため、実装する場合は opt-in の軽量 probe として設計する。

想定案:

1. 既存の `.pdf` path 判定は即採用する
2. `.pdf` で終わらないリンクは DOM 情報から PDF らしい候補に絞る
3. 絞った候補だけ `HEAD` を試す
4. `HEAD` が 405 / 403 / 情報不足の場合だけ `Range: bytes=0-1023` 付きの `GET` を試す
5. `Content-Type: application/pdf` または `Content-Disposition` の PDF filename から PDF と判定できたものだけ保存対象に昇格する

候補絞り込みの例:

- `a[download]`
- `a[type="application/pdf"]`
- `href`、link text、`aria-label`、`title` に `pdf` / `download` / `report` / `document` / `whitepaper` などが含まれる
- `/download`、`/asset`、`/file`、`/documents/` など download endpoint らしい path

安全弁の例:

- デフォルトでは現状維持し、明示オプションでのみ probe する
- 1 ページあたりの probe 件数上限を設ける
- 短い timeout と低い concurrency を使う
- batch 全体で probe 結果を cache する
- 同一 URL は fragment 除去後に 1 回だけ probe する
