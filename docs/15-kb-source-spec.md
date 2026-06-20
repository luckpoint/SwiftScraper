# 15. Knowledge Base ソース成果物仕様

## 目的
Knowledge Base 向け収集ジョブが出力する成果物の単位、識別子、保存方針を整理する。

このドキュメントは、会話で確定した仕様と、未確定部分に対する推奨案をまとめたものである。

## ステータス
- `確定`: 会話で合意済み
- `推奨`: 未確定だが現時点の推奨案

## 成果物の全体像
1 回の収集ジョブは次を出力する。

- 不変 run manifest
- ページ文書
- PDF 文書
- ページ文書化に失敗した failed page artifact

保存例:

```text
runs/<run-id>/
  manifest.json
  pages/
  pdfs/
  failed-pages/
```

## ページ文書
### 確定
- 最終成果物は `Markdown + manifest` とする
- ページ文書は PDF 文書とは別文書として保存する
- `source_id + version_id` で版管理する
- `source_id` は `canonical or resolved URL` を軸にし、`origin_url` と `discovered_from` も保持する
- `version_id` は `content-only HTML` の hash とする
- ページ文書の正本は `content-only HTML` とみなす
- `content-only` が空、または 300 文字未満ならページ文書は生成しない

### 推奨
- page sidecar metadata に `content_only_hash` と `markdown_path` を保持する
- v1 では raw HTML の永続保存は必須にしない

理由:

- ツールの責務が `収集専用` であり、成果物の主眼が KB 入力にあるため

## PDF 文書
### 確定
- PDF は一次ソースとする
- 正本は `.pdf` バイナリとする
- ページ文書とは別文書として保存する
- `source_id = normalized pdf_url`
- `version_id = content_hash`
- manifest の必須項目は `doc_id`, `pdf_url`, `downloaded_path`, `parent_page_url`, `link_text`, `content_hash`, `fetched_at`
- 同一内容の PDF は 1 文書に集約し、`parents[]` を持つ
- direct PDF は収集対象に含め、`parent_page_url = null` を許可する

### 推奨
- `doc_id` は `<source_id>@<version_id>` として manifest 上で一意に扱う
- direct PDF のときは `discovery_source` を必須にする

## failed page artifact
### 確定
- ページ取得が成功しても `content-only` が失敗した場合、ページ文書は生成しない
- その代わり failed artifact を残す
- failed page の存在は PDF 収集の provenance として使ってよい

### 推奨
最低限、次を持つ。

- `source_id`
- `resolved_url`
- `origin_url`
- `discovered_from`
- `failure_reason`
- `candidate_text_length`
- `fetched_at`

## run manifest
### 確定
- run ごとに不変の manifest を残す
- discovery で見つけた候補は `accepted / rejected / skipped` を全部残す

### 推奨
最低限、次を持つ。

- `run_id`
- `started_at`
- `finished_at`
- `input`
- `options`
- `pages`
- `pdfs`
- `failed_pages`
- `candidates`
- `summary`

`summary` の推奨項目:

- `accepted_pages`
- `accepted_pdfs`
- `rejected_count`
- `skipped_count`
- `failed_fetch_count`
- `failed_extraction_count`

## crawl state
### 確定
- run manifest とは別に mutable crawl state を持つ
- 1 レコードは `source_id` ごとの現在状態を表す
- `skip-unchanged` は `事前判定 + 取得後判定` とする
- ページ文書は保守的に扱い、原則フル取得後に unchanged を判定する

### 推奨
最低限、次を持つ。

- `source_id`
- `document_type`
- `latest_version_id`
- `last_fetch_status`
- `last_fetched_at`
- `last_successful_at`
- `etag`
- `last_modified`
- `failure_count`

保存方式の推奨:

- mutable state は SQLite

## 推奨する URL 正規化
### page
- `rel=canonical` があればそれを優先する
- なければ resolved URL を使う
- `fragment` を除去する
- `utm_*` など tracking query を除去する
- host を小文字化する

### pdf
- normalized pdf URL を `source_id` に使う
- `fragment` を除去する
- tracking query を除去する
- file extension の有無は path 実体を優先して扱う

## 推奨する decision reason
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

## 推奨する scheduler
`PDF 優先` を前提に、次を推奨する。

1. direct PDF seed / discovery result
2. explicit seed page
3. seed page から見つかった PDF
4. hop 1 page
5. hop 1 page から見つかった PDF
6. hop 2 page
7. hop 2 page から見つかった PDF

補足:

- `親ページ provenance` と `PDF 優先` の両立を狙う
- 実装時には queue の優先度を明示する

## 関連ドキュメント
- [13. Knowledge Base 向け改善ロードマップ](13-knowledge-base-roadmap.md)
- [14. 検索結果からの収集](14-search-discovery.md)
