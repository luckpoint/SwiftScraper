# 08. Batch 実行

## 目的
複数 URL をまとめて解決し、同じ待機条件・抽出条件で一括スクレイピングする。

## 要件
- `sitemap` または URL 一覧ファイルから対象 URL 群を解決できること
- 重複 URL を除去しつつ、入力順をなるべく保てること
- 並列数を制御しながら各ページを独立に処理できること
- ページ単位の成功 / 失敗を集計できること
- 最終結果を JSON として保存または標準出力へ返せること

## 入力
- `--sitemap`
- `--url-file <path>`
- `--concurrency <count>`。既定 4
- 単ページ実行と同じ待機、抽出、整形、出力先オプション

## URL ソースの解決
### `--sitemap`
- URL が `.xml` または `.xml.gz` で終わる場合は、その URL を sitemap として扱う
- それ以外の URL ではサイトルートの `/sitemap.xml` を解決対象にする
- `urlset` と `sitemapindex` を解釈し、入れ子の sitemap もたどる
- gzip 圧縮された sitemap は未対応

### `--url-file`
- 1 行 1 URL のテキストファイルを読む
- 空行と `#` で始まる行は無視する
- 重複 URL は除去する
- 不正な URL 行があれば、その時点で失敗にする

## 処理概要
1. `--sitemap` または `--url-file` から URL 群を解決する
2. `--concurrency` に基づいて並列数を制限する
3. 各 URL について単ページ実行と同じ `WebScraper` を走らせる
4. 各ページの出力に対して `--markdown` / `--pretty-print` などの整形を適用する
5. ページ単位の成功 / 失敗を集約し、最終 JSON を返す

## 出力形式
- `source.kind`: `sitemap` または `url-file`
- `source.location`: 解決に使った sitemap URL または URL ファイルパス
- `pageCount`: 総ページ数
- `successCount`: 成功ページ数
- `failureCount`: 失敗ページ数
- `pages[].url`: 対象ページ URL
- `pages[].success`: 成功可否
- `pages[].output`: 成功時の抽出結果
- `pages[].error`: 失敗時のエラーメッセージ

## 完了条件
- 対象 URL 群を最後まで処理し、batch 結果 JSON を返せること
- 全件成功なら終了コード 0、1 件でも失敗があれば終了コード 1 を返せること

## 注意点
- batch 実行時の最終出力は常に JSON で、各ページの結果が `pages[]` に入る
- `--output <path>` を指定した場合は、batch JSON 全体を 1 ファイルへ保存する
- `--concurrency` は `--sitemap` または `--url-file` と一緒に指定する
- `--sitemap` は対象サイト URL が必要で、`--url-file` は URL の同時指定と併用できない
- `--sitemap` と `--url-file` は同時指定できない
