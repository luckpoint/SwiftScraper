# 10. PDF 生成

## 目的
Markdown ファイルを HTML に変換し、macOS ネイティブのレイアウトエンジンでページネーション付き PDF を生成する。

## 要件
- Markdown ファイルを入力として A4 サイズの PDF を出力できること
- 大きなドキュメント（数万行）でもページネーションされた複数ページ PDF を生成できること
- ヘッダー・フッターなしのミニマムフォーマットであること
- Chromium や外部ツールに依存しないこと

## 入力
- Markdown ファイルパス
- 出力 PDF ファイルパス（省略時は入力ファイル名の拡張子を `.pdf` に置換）

## 処理概要
1. Markdown ファイルを読み込む
2. Ink で Markdown → HTML に変換する
3. 最小限の CSS を含む HTML テンプレートで包む
4. `NSAttributedString(data:options:.html)` で HTML → 属性付き文字列に変換する
5. `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` でレイアウトを計算する
6. `NSTextView` に配置し、`NSPrintOperation` で PDF として保存する

## 完了条件
- 指定パスに複数ページの PDF ファイルが出力されること

## WKWebView を使った PDF 生成の検証結果

開発過程で WKWebView による PDF 生成を検証した。結論として **大きなドキュメントの PDF 化には WKWebView は適さない** ことが判明した。

### 検証 1: `WKWebView.createPDF(configuration:)`

`createPDF` は Web コンテンツのスナップショットを PDF 化する API であり、**ページネーション（複数ページ分割）を行わない**。

| `WKPDFConfiguration.rect` | 挙動 |
|---|---|
| `.zero`（デフォルト） | コンテンツ全体を **1 ページ** の PDF に収める。コンテンツが大きすぎると `WKErrorDomain Code=1` で失敗する |
| A4 サイズ等を明示指定 | 指定した矩形領域のみをキャプチャする。**先頭の 1 ページ分しか出力されない** |

小さなドキュメント（数千行以下）であれば `.zero` で問題なく動作するが、1MB 超のドキュメントではエラーになった。

### 検証 2: `NSPrintOperation(view: WKWebView)`

WKWebView を `NSPrintOperation` に渡す方法も試したが、**WKWebView のレンダリングは別プロセス（WebContent プロセス）で行われるため**、NSView の印刷パイプラインではオフスクリーンのコンテンツにアクセスできない。結果として表示領域分（1 ページ分）のみが出力された。

### 検証 3: `NSAttributedString(html)` + `NSTextView`（採用）

AppKit の `NSAttributedString(data:options:.html)` で HTML を属性付き文字列に変換し、`NSTextView` + `NSPrintOperation` で PDF 化する方法を採用した。

- `NSTextContainer` の高さを `.greatestFiniteMagnitude` に設定し、全テキストをレイアウトさせる
- `NSLayoutManager.ensureLayout(for:)` でレイアウトを確定させる
- `NSPrintOperation` が `NSTextView` のページネーション機構（`knowsPageRange(_:)` / `rectForPage(_:)`）を利用して複数ページを生成する

このアプローチで 1.2MB / 22,000 行のドキュメントが 319 ページの PDF として正常に出力された。

### CSS の再現度

`NSAttributedString(data:options:.html)` は内部で旧 WebKit を使用しており、モダン CSS の再現度は WKWebView より低い。ただし、以下のような基本的なスタイリングは問題なく適用される:

- フォントファミリー・サイズ
- 見出し（h1〜h6）
- コードブロック・インラインコード
- テーブル
- リスト
- ブロック引用

## WKWebView で大きなドキュメントの PDF を作成したい場合の対応策

WKWebView のレンダリング品質（CSS Grid、Flexbox、Web フォント等）が必要な場合は、以下の方法が考えられる。

### 方法 A: ドキュメント分割 + PDF 結合

1. Markdown を見出し単位（例: `# ` レベル）で分割する
2. 各チャンクを個別に HTML 化し、`WKWebView.createPDF(configuration:)` で PDF Data を取得する
3. `PDFKit` の `PDFDocument` を使って全チャンクの PDF を結合する

```swift
import PDFKit

let merged = PDFDocument()
for chunkHTML in chunks {
    let data = try await webView.pdf(configuration: WKPDFConfiguration())
    if let chunkPDF = PDFDocument(data: data) {
        for i in 0..<chunkPDF.pageCount {
            if let page = chunkPDF.page(at: i) {
                merged.insert(page, at: merged.pageCount)
            }
        }
    }
}
merged.write(to: outputURL)
```

各チャンクが `createPDF` の上限を超えないサイズに収まるよう分割する必要がある。WKWebView の再利用にはページロード → `didFinish` → `createPDF` のサイクルを繰り返す。

### 方法 B: JavaScript によるページ分割

1. HTML にページサイズ相当の CSS を設定する（`@media print` + `@page`）
2. WKWebView でロード後、JavaScript でコンテンツの総高さを取得する
3. ページ高さごとに `createPDF(configuration:)` を `rect` を変えて呼び出す
4. `PDFKit` で結合する

```swift
let totalHeight = try await webView.evaluateJavaScript(
    "document.documentElement.scrollHeight"
) as! CGFloat
let pageHeight: CGFloat = 841.89
var y: CGFloat = 0
while y < totalHeight {
    let config = WKPDFConfiguration()
    config.rect = CGRect(x: 0, y: y, width: 595.28, height: min(pageHeight, totalHeight - y))
    let data = try await webView.pdf(configuration: config)
    // PDFKit で結合
    y += pageHeight
}
```

ただしページ境界でテキストが途中で切れる問題があり、適切な分割位置の検出が必要になる。

### 方法 C: ヘッドレスプリント（将来の可能性）

macOS の将来のバージョンで WKWebView にプログラマティックな印刷 API（ページネーション対応の PDF 出力）が追加される可能性はあるが、現時点（macOS 15 まで）では提供されていない。

## 注意点
- `NSAttributedString(data:options:.html)` はメインスレッドで呼ぶ必要がある
- `NSPrintOperation.run()` はモーダルに実行される（CFRunLoop をブロックする）
- `NSPrintOperation` で PDF 保存する場合、出力先は `jobSavingURL` で `NSPrintInfo` に設定する
- `WKWebView.createPDF` は印刷 API ではなくスナップショット API であるという認識が重要
