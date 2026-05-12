# 12. PDF リンクダウンロード

## 目的
PDF リンク集ページを `WKWebView` で描画し、ページ内の `.pdf` リンクを抽出してローカルへ保存する。

例:

```bash
swift run swift-scraper -- \
  https://www.okta.com/legal/trustandcompliance/ \
  --download-pdfs downloads \
  --auto-scroll
```

## 入力
- 対象 URL
- 保存先 root directory
- 任意のページロード補助オプション:
  - `--cookie`
  - `--cookie-file`
  - `--cookie-jar`
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

## 保存先
保存先は、指定 root directory の下に取得元ページの host と path を反映したディレクトリを作る。

```text
downloads/
  www.okta.com/
    legal/
      trustandcompliance/
        <file>.pdf
```

`https://www.okta.com/legal/trustandcompliance/` から抽出した PDF は、`downloads/www.okta.com/legal/trustandcompliance/` に保存される。

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
5. 重複 URL を除外する
6. `navigator.userAgent` から WKWebView の実 User-Agent を取得する
7. WebKit の CookieStore に残っている Cookie を PDF ダウンロード request に反映する
8. `URLSession` で PDF を取得し、取得元ページ別ディレクトリに保存する
9. stdout に JSON サマリを出力する

## User-Agent と Cookie
PDF リンクの抽出は WKWebView の描画済み DOM から行い、PDF 本体の取得は `URLSession` で行う。

`URLSession` の PDF download request には次の header を設定する。

- `--header` で指定された任意の header
- `--header 'User-Agent: ...'` がある場合は、その User-Agent
- `User-Agent` が未指定の場合は、WKWebView 内で取得した `navigator.userAgent`
- WebKit の `WKWebsiteDataStore.httpCookieStore` から取得した Cookie のうち、PDF URL の domain / path / secure / expires 条件に合う Cookie

Cookie は `Cookie` header として設定する。ただし `--header 'Cookie: ...'` が明示されている場合は、その値を優先し、自動生成した Cookie header は上書きしない。

このため、ログイン後やロケール判定後に WebKit CookieStore に入った Cookie は PDF ダウンロードにも引き継がれる。一方、`URLSession` は WebKit と同じネットワークスタックではないため、通常のブラウザ download 制御ではなく、同等の header / Cookie を明示的に再構成している。

## 出力 JSON
成功・失敗を含む全 PDF の結果を JSON で出力する。

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

終了コード:
- `0`: ページ取得と PDF ダウンロードが成功、または PDF リンクが 0 件
- `1`: ページ取得に失敗、保存先作成に失敗、または PDF の一部/全部の保存に失敗
- `2`: CLI 引数エラー

## 併用できないオプション
`--download-pdfs` は専用の 1 shot 操作モードであり、通常の抽出出力とは分離している。

- `--pdf`
- `--bidi-server`
- `--sitemap`
- `--url-file`
- `--concurrency`
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

## 制約
- 初期実装では単一ページのみ対象。`--sitemap` / `--url-file` による batch ダウンロードは未対応。
- `href` の path が `.pdf` で終わるリンクだけを対象にする。リダイレクト先が PDF になる download endpoint は対象外。
- PDF の `Content-Type` は検証しない。HTTP status が 2xx なら保存する。
- BiDi server の download 制御ではなく、CLI の 1 shot mode として実装している。
