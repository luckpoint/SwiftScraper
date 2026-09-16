# 04. HTML / DOM Extraction

## Purpose
Extract the final HTML or the required DOM information from a rendered page.

## Requirements
- Use `document.documentElement.outerHTML` as the default extraction target
- Execute extraction with `evaluateJavaScript`
- Allow extension to element-level extraction when needed
- Allow the result to remain HTML or be converted to Markdown

## Implemented extraction modes
- Default: `document.documentElement.outerHTML`
- `--body-text`: `document.body.innerText`
- `--selector-inner-html <css>`: `innerHTML` of matching elements
- `--content-only`: HTML for the likely content node
- `--inspect-structure`: summary report of content candidates and landmark counts
- `--extract-images`: apply image heuristics to HTML modes and remove unwanted images from the extraction result

## Current extraction rules
- `outerHTML` and `selector-inner-html` remove `script` and `noscript` before returning the result
- Hidden or zero-size `iframe` elements are removed from `outerHTML` and `selector-inner-html`
- `content-only` estimates the content region from candidates such as `main`, `article`, `#content`, `.article-body`, and `.entry-content`
- `content-only` removes `header`, `footer`, `nav`, `aside`, sidebar-like and hidden elements, and `script` / `noscript` / `template`
- When multiple candidates exist, the strongest candidate is selected using text volume, semantic weight, and link density
- If candidates are weak, extraction falls back to `body`
- `--extract-images` scans page `img` elements separately and keeps content-oriented images while removing logos, UI images, and tiny images
- With `--image-filter article-only`, only images classified as `inArticle` are eligible for the final output

## Output formatting
- `--pretty-print` formats HTML modes in plain output
- `--markdown` is available only for `outerHTML`, `selector-inner-html`, and `content-only`
- `--extract-images` is available only for `outerHTML`, `selector-inner-html`, and `content-only`
- `--markdown` and `--pretty-print` cannot be used together
- `--inspect-structure` creates JSON internally, but the final output is a human-readable text report
- In batch execution, each page result is stored in JSON as `pages[].output` or `pages[].error`

## Processing overview
1. Run the JavaScript for the selected extraction mode after rendering waits complete
2. Receive an HTML string, text, or inspection JSON string
3. When `--extract-images` is set, collect image candidate metadata with separate JavaScript and remove unwanted images from the HTML with Swift heuristics
4. Apply HTML formatting, Markdown conversion, or inspection report generation as needed
5. Save, analyze, or pass the result to the next stage

## Completion criteria
- The extraction result is returned to Swift as a usable string or structured data

## Notes
- Elements loaded based on viewport visibility may require additional actions before extraction
- Keep the extraction target switchable according to downstream requirements
- `--selector-inner-html` fails when no matching element is found
- For content workflows, prefer `--content-only --markdown`
- See [09. Image Extraction and Heuristics](09-image-extraction.md) for image heuristic details and CLI options
- See [08. Batch Processing](08-batch-processing.md) for batch input and output details
