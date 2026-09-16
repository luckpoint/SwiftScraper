# 08. Batch Processing

## Purpose
Resolve multiple URLs and scrape them in one run with the same wait and extraction conditions.

## Requirements
- Resolve target URLs from a sitemap or a URL list file
- Remove duplicate URLs while preserving input order as much as possible
- Process pages independently while controlling concurrency
- Aggregate per-page success and failure
- Save the final result as JSON or return it on standard output

## Inputs
- `--sitemap`
- `--url-file <path>`
- `--concurrency <count>`; defaults to 4
- The same wait, extraction, formatting, and output-destination options as single-page execution
- PDF link saving:
  - `--download-pdfs <dir>`: PDF-only batch that saves only PDF links from each page
  - `--download-linked-pdfs <dir>`: sidecar mode that saves PDF links alongside a normal scrape batch
  - `--overwrite-pdfs`: replace existing PDFs with the same name

## Resolving URL sources
### `--sitemap`
- If the URL ends in `.xml` or `.xml.gz`, treat it as the sitemap
- For other URLs, resolve the site's `/sitemap.xml`
- Interpret `urlset` and `sitemapindex`, including nested sitemaps
- Gzip-compressed sitemap contents are not supported

### `--url-file`
- Read a text file with one URL per line
- Ignore blank lines and lines beginning with `#`
- Remove duplicate URLs
- Fail immediately if an invalid URL line is found

## Processing overview
1. Resolve URLs from `--sitemap` or `--url-file`
2. Limit concurrency according to `--concurrency`
3. Run the same `WebScraper` used for a single page for every URL
4. Apply formatting such as `--markdown` or `--pretty-print` to each page result
5. Aggregate per-page success and failure and return the final JSON

With `--download-linked-pdfs`, PDF links are collected during the same `WKWebView` execution as the normal scrape for each page. PDF files are saved with `URLSession`, and the result is written to `<PDF output directory>/pdf-downloads.json`. The normal scrape batch JSON remains on stdout or at the path specified by `--output`.

With `--download-pdfs`, normal extraction is skipped. PDF links are collected and saved for every page, and the final output is the PDF download batch JSON.

## Output format
- `source.kind`: `sitemap` or `url-file`
- `source.location`: sitemap URL or URL file path used for resolution
- `pageCount`: total page count
- `successCount`: number of successful pages
- `failureCount`: number of failed pages
- `pages[].url`: target page URL
- `pages[].success`: whether the page succeeded
- `pages[].output`: extraction result on success
- `pages[].error`: error message on failure

## Completion criteria
- All target URLs are processed and a batch result JSON is returned
- Exit code 0 is returned when every page succeeds; exit code 1 is returned when at least one page fails

## Notes
- The final output of batch execution is always JSON, with each page result in `pages[]`
- With `--output <path>`, save the entire batch JSON to one file
- Use `--concurrency` together with `--sitemap` or `--url-file`
- `--sitemap` requires the target site URL; `--url-file` cannot be combined with a positional URL
- `--sitemap` and `--url-file` cannot be used together
- `--cookie-jar` cannot be used for batch execution
