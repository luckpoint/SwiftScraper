# 04. HTML / DOM 取得

## 目的
レンダリング後のページから最終 HTML、または必要な DOM 情報を取得する。

## 要件
- 基本取得対象を `document.documentElement.outerHTML` とすること
- `evaluateJavaScript` を用いて実行できること
- 必要に応じて要素単位の抽出へ拡張できること
- 取得後に HTML のまま出すか、Markdown に変換して出力できること

## 実装済み抽出モード
- 既定: `document.documentElement.outerHTML`
- `--body-text`: `document.body.innerText`
- `--selector-inner-html <css>`: 一致要素の `innerHTML`
- `--content-only`: 本文候補ノードの HTML
- `--inspect-structure`: 本文候補とランドマーク数の要約レポート
- `--extract-images`: HTML 系モードに対して画像 heuristic を適用し、不要画像を抽出結果から除去

## 現在の抽出仕様
- `outerHTML` と `selector-inner-html` では `script` / `noscript` を除去して返す
- 非表示またはサイズ 0 の `iframe` は `outerHTML` と `selector-inner-html` から除去する
- `content-only` は `main` / `article` / `#content` / `.article-body` / `.entry-content` などを候補に本文領域を推定する
- `content-only` は `header` / `footer` / `nav` / `aside`、sidebar 系、hidden 系、`script` / `noscript` / `template` を除去する
- 候補が複数ある場合は、テキスト量、意味的な重み、リンク密度から最良候補を選ぶ
- 候補が弱い場合は `body` へフォールバックする
- `--extract-images` はページ上の `img` 要素を別途走査し、本文寄りの画像を残してロゴ / UI / 極小画像を除去する
- `--image-filter article-only` を指定すると、`inArticle` 判定の画像だけを最終出力対象にする

## 出力整形
- `--pretty-print` は plain 出力の HTML 系モードを整形する
- `--markdown` は `outerHTML` / `selector-inner-html` / `content-only` でだけ利用できる
- `--extract-images` も `outerHTML` / `selector-inner-html` / `content-only` でだけ利用できる
- `--markdown` と `--pretty-print` は同時指定できない
- `--inspect-structure` は内部的に JSON を作るが、最終出力は人間向けのテキストレポートになる
- batch 実行時は各ページ結果を JSON の `pages[].output` / `pages[].error` に格納する

## 処理概要
1. レンダリング待機完了後に抽出モードごとの JavaScript を実行する
2. HTML 文字列、テキスト、または inspection 用 JSON 文字列を受け取る
3. `--extract-images` 指定時は画像候補メタデータを別 JS で回収し、Swift 側 heuristic で HTML から不要画像を除去する
4. 必要に応じて HTML 整形、Markdown 変換、inspection レポート化を行う
5. 保存、解析、次工程への受け渡しを行う

## 完了条件
- 取得結果を Swift 側で利用可能な文字列または構造化データとして回収できること

## 注意点
- 可視領域依存で読み込まれる要素は、取得前に追加操作が必要になる場合がある
- 取得対象は後続処理の要件に応じて切り替え可能にしておく
- `--selector-inner-html` は一致要素が見つからない場合にエラーになる
- 本文用途では `--content-only --markdown` の組み合わせを優先する
- 画像 heuristic の詳細と CLI は `docs/09-image-extraction.md` を参照する
- batch 実行の入出力仕様は `docs/08-batch-processing.md` を参照する
