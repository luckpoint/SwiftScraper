# 13. Knowledge Base Improvement Roadmap

## Purpose
Extend SwiftScraper from a CLI that fetches dynamic pages into a foundation that reliably collects sources for a knowledge base such as NotebookLM.

This document summarizes current agreements and recommended policies for unresolved issues.

## Scope
- 4. Recrawling and incremental updates
- 5. Collection from search results
- 6. Stronger operational resilience

## Confirmed assumptions
### Product responsibility
- SwiftScraper is responsible for collection only
- Search, summarization, conversational UI, and vector search belong to external systems

### Final artifacts
- Page documents are delivered as `Markdown + manifest`
- PDFs are stored as primary sources and treated as separate documents from page documents
- An immutable manifest for each run is stored under `runs/<run-id>/...`

### Inputs and discovery scope
- Collection jobs accept both known URLs and search queries
- Search-result collection is limited to allowlisted domains
- Link expansion defaults to `1 hop`, with `0-2 hop` selectable at runtime
- The stopping conditions are separate `max-pages` and `max-pdfs` limits

### Collection priority
- The overall policy is `PDF first`
- PDFs found through an HTML parent page retain their provenance
- Direct PDF URLs are also collection targets

### Document model
- Page documents and PDF documents are output separately
- Page documents are managed with `source_id + version_id`
- PDF documents are also managed with `source_id + version_id`
- A page document's `version_id` is the hash of its `content-only HTML`
- A PDF document's `version_id` is the PDF binary's `content_hash`

### Recrawling
- Keep mutable `crawl state` for recrawl decisions separately from the run manifest
- Use `source_id` as the crawl-state primary key
- Implement `skip-unchanged` as a pre-fetch check plus a post-fetch check
- Treat page documents conservatively and generally determine unchanged status from the final hash after a full fetch

## Specification notes
### Page documents
- Base `source_id` on the canonical or resolved URL
- Keep `origin_url` and `discovered_from`
- Treat `content-only HTML` as the canonical source
- The final artifact is Markdown plus a manifest
- Do not generate a page document when `content-only` is empty or shorter than 300 characters
- Keep pages that fail document generation as failed artifacts

### PDF documents
- Treat the `.pdf` binary as canonical
- The manifest contains `doc_id`, `pdf_url`, `downloaded_path`, `parent_page_url`, `link_text`, `content_hash`, and `fetched_at`
- Model `doc_id` with two layers: `source_id = normalized pdf_url` and `version_id = content_hash`
- If identical PDF content is found from multiple parents, consolidate it into one document with `parents[]`
- For direct PDFs, allow `parent_page_url = null`

## Dependencies
The three themes are not independent and should be introduced in this order:

1. Crawl state and run manifest
2. `skip-unchanged` and incremental updates
3. Discovery and allowlist control
4. Operational resilience such as `.xml.gz`, retry, rate limiting, and robots

Reasons:

- Adding discovery first would leave run-level accountability weak
- Adding incremental updates first would keep the input origin limited to known URLs
- Expanding discovery before operational resilience would make failure modes difficult to understand

## Recommended unresolved decisions
### 1. URL normalization
Recommendation:

- For pages, prefer `rel=canonical`, otherwise use the resolved URL
- Remove `fragment`
- Remove tracking queries such as `utm_*`
- Lowercase the host
- Apply only obvious path normalization and avoid aggressively merging locale or synonymous paths

Reason:

- This reduces basic duplication while avoiding incorrect merging of source IDs

### 2. Crawl-state storage
Recommendation:

- Store run artifacts immutably as JSON
- Use SQLite for mutable crawl state

Reasons:

- Upserts and latest-value lookups by `source_id` are straightforward
- Auditing past runs and representing current state remain separate responsibilities

### 3. Rejection-reason taxonomy
Recommendation:

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

Reasons:

- This fits the policy of retaining all accepted, rejected, and skipped candidates
- The same values can be reused for later auditing, retries, and quality improvements

### 4. Concrete PDF-first scheduling
Recommendation:

1. Secure direct PDF seed and discovery results first
2. Fetch explicit seed HTML pages
3. Prioritize PDFs found from HTML parent pages
4. Process hop 1 HTML
5. Process hop 2 HTML

Reasons:

- It balances the PDF-first policy with parent-page provenance
- Additional HTML exploration is less likely to consume all item limits

### 5. robots.txt
Recommendation:

- In the initial implementation, interpret `robots.txt` explicitly and reject URLs that violate `Disallow` as `robots_disallowed`
- Apply the same policy to direct PDF URLs

Reason:

- Even with an allowlist, ongoing collection needs explicit rules for consistent operational decisions

## Implementation order
### P0
- Standard run manifest schema
- Source models for page, PDF, and failed artifacts
- Crawl-state introduction
- `.xml.gz` sitemap support
- Retry, backoff, and per-domain concurrency control

### P1
- `--discover` and provider abstraction
- Allowlist control
- Recording accepted, rejected, and skipped candidates
- Unified provenance for direct PDFs and PDFs found through HTML parent pages

### P2
- Improve pre-fetch `skip-unchanged` checks
- Explicit `robots.txt` support
- Aggregate rejection reasons and strengthen the run summary

## Related documents
- [14. Search Result Discovery](14-search-discovery.md)
- [15. Knowledge Base Source Artifact Specification](15-kb-source-spec.md)
