# 09. Image Extraction and Heuristics

## Purpose
Keep content-oriented images while removing logos, UI icons, advertisements, and tiny images from HTML and Markdown output.

## Adopted approach
- Collect image candidate features with JavaScript
- Score candidates and apply thresholds in Swift
- Remove images from the final HTML on the Swift side

This split keeps DOM-dependent observation flexible while keeping the decision logic maintainable in Swift.

## Current implementation scope
Implemented:
- Collect candidate metadata from `document.images`
- Apply strong penalties to `header/nav + home link + logo keyword`
- Penalize small images
- Reward `article/main/figure/figcaption`
- Provide debug output with `reasons`
- Support the `article-only` filter
- Remove `img` elements before HTML / Markdown output

Not implemented:
- Cross-page common-image frequency adjustment during batch execution
- Domain-specific blacklists or whitelists
- `background-image` and `canvas` support

## Features collected on the JavaScript side
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

The return value is an array serialized with `JSON.stringify(...)), which Swift decodes as `ImageCandidate`.

## Swift-side decision
The initial score is `0.5`.

Main positive signals:
- `inArticle`
- `inFigure`
- `figcaption` present
- Sufficient rendered size
- Sufficient source image size
- Descriptive `alt` text
- Near a content text block
- Large area suggesting a hero image

Main negative signals:
- Context keywords such as `logo`, `icon`, `nav`, `header`, `footer`, `share`, and `ad`
- `header`, `nav`, `footer`, and `aside`
- Image linked to the home page
- SVG
- Tiny image
- Extremely wide image
- Small `data:` URI

Decision:
```text
score >= threshold    keep
0.40..<threshold      maybe
< 0.40                drop
```

The default `threshold` is `0.65`.

## The article-only filter
With `--image-filter article-only`, images where `inArticle == false` are treated as `drop` in the final output.

This is an output filter separate from the heuristic score, and it adds `filtered_article_only` to `reasons`.

## Applying the result to output
`--extract-images` is available only for HTML extraction modes.

Processing order:
1. Perform normal HTML extraction
2. Collect image candidate metadata with JavaScript
3. Score candidates in Swift
4. Keep `keep` candidates and, when requested, `maybe` candidates
5. Remove unwanted `img` elements from the HTML
6. Apply `--markdown` or `--pretty-print`

If removing an image leaves a `figure` empty, remove the entire `figure` as well.

## CLI
```text
--extract-images
--image-filter all|article-only
--image-score-threshold 0.65
--image-include-maybe
--image-debug
```

### Recommended example
```bash
swift run swift-scraper -- \
  https://example.com/article \
  --content-only \
  --markdown \
  --extract-images \
  --image-filter article-only \
  --image-debug
```

## Debugging
With `--image-debug`, one line of JSON is written to stderr.

Main fields:
- `pageURL`
- `filter`
- `scoreThreshold`
- `includeMaybe`
- `score`, `decision`, and `reasons` for each image

Use this JSON to tune the keyword dictionary and threshold.

## Notes
- Some sites place article hero images inside `header`, so `header` is penalized rather than immediately excluded
- `article-only` is a strong filter and may omit hero images that sit outside the article region
- The current decision uses only context within one page, so excluding site-wide assets requires batch frequency adjustment
