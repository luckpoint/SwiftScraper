# 09. 画像抽出と heuristic

## 目的
本文寄りの画像は残しつつ、ロゴ、UI アイコン、広告、極小画像を HTML / Markdown 出力から除去する。

## 採用方針
- 画像候補の特徴量収集は JavaScript で行う
- スコアリングと閾値判定は Swift で行う
- HTML の最終除去は Swift 側で行う

この分割により、DOM 依存の観測は柔軟に保ちつつ、判定ロジックは Swift で保守できる。

## 現在の実装範囲
実装済み:
- `document.images` から候補メタデータを収集
- `header/nav + home link + logo keyword` を強く減点
- 小さい画像を減点
- `article/main/figure/figcaption` を加点
- `reasons` を出せるデバッグ出力
- `article-only` フィルタ
- HTML / Markdown 出力前の `img` 除去

未実装:
- batch 実行での同一ホスト共通画像頻度補正
- ドメイン別 blacklist / whitelist
- `background-image` / `canvas` 対応

## JS 側で収集する特徴量
- `currentSrc`, `src`
- `alt`, `title`
- `naturalWidth`, `naturalHeight`
- `renderedWidth`, `renderedHeight`
- `top`, `left`
- `isVisible`
- `inArticle`, `inHeader`, `inNav`, `inFooter`, `inAside`
- `inFigure`, `figcaption`
- `linkedHref`, `linkedToRoot`
- `id`, `className`, `ancestors`
- `filename`
- `isDataUri`, `isSvg`
- `nearestTextBlockLength`

返り値は `JSON.stringify(...)` した配列で、Swift 側では `ImageCandidate` として decode する。

## Swift 側の判定
初期スコアは `0.5`。

主な加点:
- `inArticle`
- `inFigure`
- `figcaption` あり
- 十分な表示サイズ
- 十分な元画像サイズ
- 説明的な `alt`
- 本文ブロック近傍
- ヒーロー画像らしい大面積

主な減点:
- `logo`, `icon`, `nav`, `header`, `footer`, `share`, `ad` などの文脈キーワード
- `header` / `nav` / `footer` / `aside`
- ホームリンク画像
- SVG
- 極小画像
- 極端な横長画像
- 小さい `data:` URI

判定:
```text
score >= threshold    keep
0.40..<threshold      maybe
< 0.40                drop
```

既定の `threshold` は `0.65`。

## article-only フィルタ
`--image-filter article-only` を指定した場合は、`inArticle == false` の画像を最終的に `drop` 扱いにする。

これは heuristic スコアとは別の出力フィルタであり、`reasons` に `filtered_article_only` を追加する。

## 出力への反映
`--extract-images` は HTML 系抽出モードだけで有効。

処理順:
1. 通常の HTML 抽出を行う
2. 画像候補メタデータを JS で収集する
3. Swift でスコアリングする
4. `keep`、必要なら `maybe` だけ残す
5. HTML から不要な `img` を除去する
6. その後に `--markdown` / `--pretty-print` を適用する

`figure` 内の画像を落とした結果 `figure` が空になった場合、その `figure` ごと除去する。

## CLI
```text
--extract-images
--image-filter all|article-only
--image-score-threshold 0.65
--image-include-maybe
--image-debug
```

### 推奨例
```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --extract-images \
  --image-filter article-only \
  --image-debug
```

## デバッグ
`--image-debug` を付けると、stderr に JSON を 1 行で出す。

主な内容:
- `pageURL`
- `filter`
- `scoreThreshold`
- `includeMaybe`
- 各画像の `score`, `decision`, `reasons`

この JSON を見ながらキーワード辞書や閾値を調整する。

## 注意点
- `header` 内に記事ヒーロー画像があるサイトもあるため、`header` は即除外ではなく減点に留める
- `article-only` は強いフィルタなので、ヒーロー画像が本文外にあるサイトでは取りこぼしうる
- 現時点では 1 ページ内の文脈だけで判定するため、サイト共通アセット除外は batch 頻度補正の追加が必要
