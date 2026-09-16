# 10. PDF Generation

## Purpose
Convert a Markdown file to HTML and generate a paginated PDF with macOS's native layout engine.

## Requirements
- Accept a Markdown file and produce an A4 PDF
- Generate a multi-page, paginated PDF for large documents with tens of thousands of lines
- Use a minimal format without headers or footers
- Avoid dependencies on Chromium or external tools

## Inputs
- Markdown file path
- Output PDF path; when omitted, replace the input file extension with `.pdf`

## Processing overview
1. Read the Markdown file
2. Convert Markdown to HTML with Ink
3. Wrap it in an HTML template with minimal CSS
4. Convert HTML to an attributed string with `NSAttributedString(data:options:.html)`
5. Calculate layout with `NSTextStorage`, `NSLayoutManager`, and `NSTextContainer`
6. Place the content in `NSTextView` and save it as PDF with `NSPrintOperation`

## Completion criteria
- A multi-page PDF is written to the specified path

## Results of validating PDF generation with WKWebView

WKWebView-based PDF generation was evaluated during development. The conclusion was that **WKWebView is unsuitable for converting large documents to PDF**.

### Test 1: `WKWebView.createPDF(configuration:)`

`createPDF` is an API that turns a snapshot of web content into a PDF; it does **not paginate content across multiple pages**.

| `WKPDFConfiguration.rect` | Behavior |
|---|---|
| `.zero` (default) | Fits all content on **one page**. If the content is too large, it fails with `WKErrorDomain Code=1` |
| Explicit A4 size or similar | Captures only the specified rectangle. **Only the first page is produced** |

Small documents, generally a few thousand lines or fewer, work with `.zero`, but documents larger than 1 MB failed.

### Test 2: `NSPrintOperation(view: WKWebView)`

Passing WKWebView to `NSPrintOperation` was also tested. Because WKWebView renders in a separate WebContent process, the NSView printing pipeline cannot access off-screen content. As a result, only the visible area, roughly one page, was output.

### Test 3: `NSAttributedString(html)` + `NSTextView` (adopted)

The adopted approach converts HTML to an attributed string with AppKit's `NSAttributedString(data:options:.html)`, then creates the PDF with `NSTextView` and `NSPrintOperation`.

- Set the height of `NSTextContainer` to `.greatestFiniteMagnitude` so all text is laid out
- Finalize layout with `NSLayoutManager.ensureLayout(for:)`
- Let `NSPrintOperation` use `NSTextView`'s pagination methods (`knowsPageRange(_:)` / `rectForPage(_:)`) to generate multiple pages

With this approach, a 1.2 MB, 22,000-line document was successfully written as a 319-page PDF.

### CSS fidelity

`NSAttributedString(data:options:.html)` uses an older WebKit internally, so its support for modern CSS is lower than WKWebView's. The following basic styles are applied reliably:

- Font family and size
- Headings (h1 through h6)
- Code blocks and inline code
- Tables
- Lists
- Block quotes

## Options for creating large PDFs with WKWebView

When WKWebView rendering quality such as CSS Grid, Flexbox, or web fonts is required, consider the following approaches.

### Method A: Split the document and merge PDFs

1. Split Markdown at heading boundaries, such as level `# `
2. Convert each chunk to HTML and obtain PDF data with `WKWebView.createPDF(configuration:)`
3. Merge all chunk PDFs with `PDFKit`'s `PDFDocument`

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

Each chunk must stay below the size at which `createPDF` fails. Reusing WKWebView requires repeating the page load, `didFinish`, and `createPDF` cycle.

### Method B: Split pages with JavaScript

1. Set page-size CSS in the HTML with `@media print` and `@page`
2. After loading in WKWebView, obtain the total content height with JavaScript
3. Call `createPDF(configuration:)` for each page height with a different `rect`
4. Merge the results with `PDFKit`

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
    // Merge with PDFKit
    y += pageHeight
}
```

Text can be cut at page boundaries, so suitable split positions must be detected.

### Method C: Headless printing (future possibility)

Future macOS versions may add a programmatic, paginated printing API for WKWebView. As of macOS 15, no such API is available.

## Notes
- `NSAttributedString(data:options:.html)` must be called on the main thread
- `NSPrintOperation.run()` executes modally and blocks the CFRunLoop
- When saving a PDF with `NSPrintOperation`, set the output path on `NSPrintInfo` through `jobSavingURL`
- It is important to treat `WKWebView.createPDF` as a snapshot API rather than a printing API
