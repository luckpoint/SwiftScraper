# 14. 検索結果からの収集

## 目的
query を起点に検索結果ページから候補 URL / PDF を集め、そのまま SwiftScraper の収集ジョブへ流し込めるようにする。

この機能は、当初の「ウェブから情報収集してナレッジベースのソースを作る」という用途に最も近い拡張である。

## 現時点で確定している前提
### 入力
- 収集ジョブの入口は `既知 URL` と `検索クエリ` の両方を持つ
- discovery はそのうち `検索クエリ` 起点の入口を担う

### 探索対象
- discovery で採用する対象は `allowlist ドメインのみ`
- 一般 Web 全体への拡張は行わない

### 深さと上限
- link expansion は既定 `1 hop`
- 実行時に `0-2 hop` を指定可能
- 停止条件は `max-pages` と `max-pdfs`

### 保存方針
- 発見した候補は `accepted / rejected / skipped` を全部 run artifact に残す
- direct PDF URL も discovery の採用対象に含める
- direct PDF の場合は `parent_page_url = null` を許可する

## 現状
現時点では Google / Yahoo! JAPAN 向けの probe script があり、BiDi bridge 経由で検索結果抽出の土台はある。

- `scripts/puppeteer-google-search.mjs`
- `scripts/puppeteer-yahoo-search.mjs`

ただし、これは確認用スクリプトであり、CLI 本体の discovery workflow には統合されていない。

## 目標 UX
### discovery 単体
```bash
swift run swift-scraper -- \
  --discover "swift web scraping" \
  --provider yahoo \
  --allow-host swift.org \
  --allow-host developer.apple.com \
  --max-results 20 \
  --output out/discovery.json
```

### discovery から scrape へ直結
```bash
swift run swift-scraper -- \
  --discover "swift web scraping" \
  --provider yahoo \
  --allow-host swift.org \
  --max-results 20 \
  --max-pages 50 \
  --max-pdfs 100 \
  --hop-depth 1 \
  --content-only \
  --markdown \
  --output out/knowledge-run.json
```

### discovery と crawl state の併用
```bash
swift run swift-scraper -- \
  --discover "swift web scraping" \
  --provider yahoo \
  --allow-host swift.org \
  --state-db state/crawl-state.sqlite \
  --skip-unchanged \
  --max-pages 50 \
  --max-pdfs 100 \
  --hop-depth 1 \
  --content-only \
  --markdown
```

## CLI 設計
### discovery 入力
- `--discover <query>`
- `--provider <name>`
- `--allow-host <host>`
- `--max-results <count>`
- `--hop-depth <0-2>`
- `--max-pages <count>`
- `--max-pdfs <count>`
- `--skip-unchanged`

### discovery 出力モード
- `results-only`: discovery 結果のみ返す
- `scrape`: discovery 結果をそのまま収集ジョブへ流し、run manifest を返す

## 内部モデル
### DiscoveryCandidate
- `candidate_type`: `page` | `pdf`
- `url`
- `title`
- `snippet`
- `provider`
- `query`
- `rank`
- `discovered_at`
- `accepted`
- `decision_reason`

### Referrer
- `type`: `query` | `seed` | `page`
- `value`
- `link_text`

### DiscoveryRunResult
- `query`
- `provider`
- `fetched_at`
- `candidate_count`
- `accepted_count`
- `rejected_count`
- `skipped_count`
- `candidates[]`
- `errors[]`

## 発見から収集までの流れ
1. query から検索結果一覧を取得する
2. allowlist に合わない URL を `rejected_allowlist` にする
3. direct PDF と page URL を candidate として分離する
4. duplicate を潰す
5. crawl state で `skip-unchanged` 候補を判定する
6. `max-pages` / `max-pdfs` に基づき採用対象を決める
7. accepted / rejected / skipped を全部 run artifact に残す
8. accepted だけを収集フェーズへ渡す

## direct PDF の扱い
- direct PDF は発見対象に含める
- `parent_page_url` は `null` を許可する
- provenance は `discovery_source=query|seed` を必須にする
- HTML 親ページ由来 PDF と同じ PDF 文書に集約される可能性がある

## 推奨する provider 実装方針
### 初期段階
- `Yahoo! JAPAN` を優先する
- 既存 Node/Puppeteer probe を JSON 出力対応して流用する
- Swift 本体は provider ごとの JSON 契約を decode する責務を持つ

### 後段
- provider 抽象を Swift 側へ寄せる
- Google provider を正式化する

## 推奨する失敗理由
- `blocked`
- `layout-changed`
- `empty-results`
- `navigation-failed`
- `timeout`
- `rejected_allowlist`
- `rejected_depth`
- `rejected_limit`
- `rejected_duplicate`
- `skipped_unchanged`

## 推奨する優先順位
`PDF 優先` を具体化するため、次の順を推奨する。

1. direct PDF seed / discovery result
2. 明示 seed HTML page
3. 明示 seed page から見つかった PDF
4. hop 1 HTML page
5. hop 1 から見つかった PDF
6. hop 2 HTML page
7. hop 2 から見つかった PDF

備考:

- これは `PDF 優先` と `親ページ provenance` を両立しやすい暫定案である
- 実装時には `max-pages` / `max-pdfs` の消費順を明文化する

## テスト方針
### ユニットテスト
- provider JSON の decode
- allowlist filter
- duplicate 判定
- accepted / rejected / skipped の分類

### 結合テスト
- ローカル fixture HTML での discovery result 抽出
- discovery 結果から scrape queue への接続

### 手動 smoke test
- `yahoo`
- `google`

実サイト依存テストは CI の主軸には置かない。

## 関連ドキュメント
- [13. Knowledge Base 向け改善ロードマップ](13-knowledge-base-roadmap.md)
- [15. Knowledge Base ソース成果物仕様](15-kb-source-spec.md)
