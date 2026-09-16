# 15. Knowledge Base Source Artifact Specification

## Purpose
Define the unit, identifiers, and storage policy for artifacts produced by a collection job that feeds a knowledge base.

This document summarizes specifications confirmed in discussion and recommendations for unresolved areas.

## Status
- `Confirmed`: agreed in discussion
- `Recommended`: unresolved, but recommended at present

## Artifact overview
One collection job produces:

- An immutable run manifest
- Page documents
- PDF documents
- Failed page artifacts for pages that could not be converted to documents

Example storage:

```text
runs/<run-id>/
  manifest.json
  pages/
  pdfs/
  failed-pages/
```

## Page documents
### Confirmed
- The final artifact is `Markdown + manifest`
- Page documents are stored separately from PDF documents
- Versions are managed with `source_id + version_id`
- `source_id` is based on the canonical or resolved URL, and also retains `origin_url` and `discovered_from`
- `version_id` is the hash of `content-only HTML`
- `content-only HTML` is the canonical page document source
- Do not generate a page document when `content-only` is empty or shorter than 300 characters

### Recommended
- Keep `content_only_hash` and `markdown_path` in page sidecar metadata
- Raw HTML persistence is not required in v1

Reason:

- The tool is responsible for collection only, and the artifacts are primarily intended as knowledge-base inputs

## PDF documents
### Confirmed
- PDFs are primary sources
- The canonical source is the `.pdf` binary
- PDFs are stored separately from page documents
- `source_id = normalized pdf_url`
- `version_id = content_hash`
- Required manifest fields are `doc_id`, `pdf_url`, `downloaded_path`, `parent_page_url`, `link_text`, `content_hash`, and `fetched_at`
- Identical PDF content is consolidated into one document with `parents[]`
- Direct PDFs are collection targets and may use `parent_page_url = null`

### Recommended
- Make `doc_id` unique in the manifest as `<source_id>@<version_id>`
- Require `discovery_source` for direct PDFs

## Failed page artifacts
### Confirmed
- If page retrieval succeeds but `content-only` fails, do not generate a page document
- Keep a failed artifact instead
- A failed page may be used as provenance for PDF collection

### Recommended
At minimum, include:

- `source_id`
- `resolved_url`
- `origin_url`
- `discovered_from`
- `failure_reason`
- `candidate_text_length`
- `fetched_at`

## Run manifest
### Confirmed
- Keep an immutable manifest for each run
- Keep every candidate found by discovery as `accepted / rejected / skipped`

### Recommended
At minimum, include:

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

Recommended `summary` fields:

- `accepted_pages`
- `accepted_pdfs`
- `rejected_count`
- `skipped_count`
- `failed_fetch_count`
- `failed_extraction_count`

## Crawl state
### Confirmed
- Keep mutable crawl state separately from the run manifest
- Each record represents the current state for one `source_id`
- Implement `skip-unchanged` as a pre-fetch check plus a post-fetch check
- Treat page documents conservatively and generally determine unchanged status after a full fetch

### Recommended
At minimum, include:

- `source_id`
- `document_type`
- `latest_version_id`
- `last_fetch_status`
- `last_fetched_at`
- `last_successful_at`
- `etag`
- `last_modified`
- `failure_count`

Recommended storage:

- Store mutable state in SQLite

## Recommended URL normalization
### Page
- Prefer `rel=canonical` when present
- Otherwise use the resolved URL
- Remove `fragment`
- Remove tracking queries such as `utm_*`
- Lowercase the host

### PDF
- Use the normalized PDF URL as `source_id`
- Remove `fragment`
- Remove tracking queries
- Prefer the actual path over the presence or absence of a file extension

## Recommended decision reasons
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

## Recommended scheduler
Assuming `PDF first`, use this order:

1. Direct PDF seed or discovery result
2. Explicit seed page
3. PDFs found from a seed page
4. Hop 1 page
5. PDFs found from a hop 1 page
6. Hop 2 page
7. PDFs found from a hop 2 page

Notes:

- This balances parent-page provenance with `PDF first`
- The implementation should make queue priorities explicit

## Related documents
- [13. Knowledge Base Improvement Roadmap](13-knowledge-base-roadmap.md)
- [14. Search Result Discovery](14-search-discovery.md)
