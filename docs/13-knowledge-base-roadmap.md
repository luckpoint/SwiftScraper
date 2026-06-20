# 13. Knowledge Base 向け改善ロードマップ

## 目的
SwiftScraper を「動的ページを取得する CLI」から、「NotebookLM のようなナレッジベースへ投入するソースを安定収集する基盤」へ拡張する。

このドキュメントは、現在の合意事項と、未確定論点に対する推奨方針をまとめたロードマップである。

## 対象テーマ
- 4. 再クロールと差分更新
- 5. 検索結果からの収集
- 6. 運用耐性の強化

## 現時点で確定している前提
### プロダクトの責務
- SwiftScraper の責務は `収集専用` とする
- 検索、要約、対話 UI、ベクトル検索は外部システムの責務とする

### 最終成果物
- ページ文書は `Markdown + manifest` を成果物とする
- PDF は一次ソースとして保存し、ページ文書とは別文書として扱う
- run ごとの不変 manifest を `runs/<run-id>/...` に保存する

### 入力と探索範囲
- 収集ジョブの入口は `既知 URL 起点 + 検索クエリ起点` のハイブリッドとする
- 検索結果からの収集対象は `allowlist ドメインのみ` とする
- link expansion は `既定 1 hop`、実行時に `0-2 hop` を指定可能とする
- 停止条件は `max-pages` と `max-pdfs` の二重上限とする

### 収集優先順位
- 大方針として `PDF 優先` とする
- ただし HTML 親ページ経由で見つかった PDF は provenance を残す
- direct PDF URL も収集対象に含める

### 文書モデル
- ページ文書と PDF 文書は別々に出力する
- ページ文書は `source_id + version_id` で管理する
- PDF 文書も `source_id + version_id` で管理する
- ページ文書の `version_id` は `content-only HTML` の hash とする
- PDF 文書の `version_id` は PDF バイナリの `content_hash` とする

### 再クロール
- run manifest とは別に、再クロール判定用の mutable `crawl state` を持つ
- crawl state の主キーは `source_id` とする
- `skip-unchanged` は `事前判定 + 取得後判定` とする
- ただしページ文書は保守的に扱い、原則フル取得後に最終 hash で unchanged 判定する

## 仕様メモ
### ページ文書
- `source_id` は `canonical or resolved URL` を軸にする
- `origin_url` と `discovered_from` を保持する
- 正本は `content-only HTML` とみなす
- 最終成果物は Markdown と manifest である
- `content-only` が空、または 300 文字未満ならページ文書は生成しない
- 文書生成に失敗したページは failed artifact として保持する

### PDF 文書
- 正本は `.pdf` バイナリとする
- manifest には `doc_id`, `pdf_url`, `downloaded_path`, `parent_page_url`, `link_text`, `content_hash`, `fetched_at` を持つ
- `doc_id` は `source_id = normalized pdf_url` と `version_id = content_hash` の二層で扱う
- 同一内容の PDF が複数の親から見つかった場合は 1 文書に集約し、`parents[]` を持つ
- direct PDF の場合は `parent_page_url = null` を許可する

## 依存関係
3 テーマは独立ではなく、次の順で入れる。

1. crawl state と run manifest
2. `skip-unchanged` と差分更新
3. discovery と allowlist 制御
4. `.xml.gz`、retry、rate limit、robots などの運用耐性

理由:

- discovery だけ先に入れても、run 単位の説明責任が弱い
- 差分更新だけ先に入れても、入力起点が既知 URL に閉じる
- 運用耐性が弱いまま探索を広げると失敗モードが読めない

## 推奨する未確定事項
### 1. URL 正規化
推奨:

- page は `rel=canonical` を優先し、なければ resolved URL を使う
- `fragment` は除去する
- `utm_*` など tracking query は除去する
- host は小文字化する
- path の明らかな正規化だけを行い、locale や同義 path の積極統合は避ける

理由:

- source_id の誤統合を避けつつ、基本的な重複は抑えられる

### 2. crawl state の保存方式
推奨:

- run artifact は JSON で不変保存
- mutable crawl state は SQLite を推奨

理由:

- `source_id` ごとの upsert と最新値参照が素直
- 過去 run の監査と現在状態の責務を分離できる

### 3. 不採用理由の taxonomy
推奨:

- `accepted`
- `rejected_allowlist`
- `rejected_depth`
- `rejected_limit`
- `rejected_duplicate`
- `skipped_unchanged`
- `failed_fetch`
- `failed_extraction`
- `failed_download`
- `blocked`
- `timeout`
- `robots_disallowed`

理由:

- accepted / rejected / skipped を全部残す方針と相性がよい
- 後続の監査、再試行、品質改善で使い回しやすい

### 4. PDF 優先の具体的なスケジューリング
推奨:

1. direct PDF seed / discovery 結果を先に確保する
2. 明示 seed の HTML ページを取得する
3. HTML 親ページから見つかった PDF を優先投入する
4. hop 1 の HTML を処理する
5. hop 2 の HTML を処理する

理由:

- `PDF 優先` と `親ページ provenance` の両立がしやすい
- 追加 HTML 探索で件数上限を食い潰しにくい

### 5. robots.txt
推奨:

- 初期実装では `robots.txt` を明示的に解釈し、`Disallow` に反する URL は `robots_disallowed` として落とす
- direct PDF URL も同じポリシーで判定する

理由:

- allowlist のみであっても、継続収集では明示ルールがないと運用判断がぶれる

## 実装順序
### P0
- run manifest の標準 schema
- page / pdf / failed artifact の source model
- crawl state の導入
- `.xml.gz` sitemap 対応
- retry / backoff / ドメイン単位並列制御

### P1
- `--discover` と provider 抽象
- allowlist 制御
- accepted / rejected / skipped の記録
- direct PDF と HTML 親ページ由来 PDF の provenance 統一

### P2
- `skip-unchanged` の事前判定改善
- `robots.txt` の明示対応
- 不採用理由の集計と run summary 強化

## 関連ドキュメント
- [14. 検索結果からの収集](14-search-discovery.md)
- [15. Knowledge Base ソース成果物仕様](15-kb-source-spec.md)
