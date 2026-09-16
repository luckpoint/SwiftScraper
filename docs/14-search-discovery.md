# 14. Search Result Discovery

## Purpose
Collect candidate URLs and PDFs from search-result pages starting from a query, then pass them directly into a SwiftScraper collection job.

This is the extension closest to the original use case of collecting information from the web and creating knowledge-base sources.

## Confirmed assumptions
### Inputs
- A collection job accepts both known URLs and search queries
- Discovery provides the search-query entry point

### Discovery scope
- Discovery accepts candidates only from allowlisted domains
- It does not expand to the entire public web

### Depth and limits
- Link expansion defaults to `1 hop`
- Runtime configuration may select `0-2 hop`
- The stopping conditions are `max-pages` and `max-pdfs`

### Storage policy
- Keep all discovered candidates as `accepted / rejected / skipped` in the run artifact
- Direct PDF URLs are eligible discovery targets
- For direct PDFs, allow `parent_page_url = null`

## Current status
Probe scripts for Google and Yahoo! JAPAN provide a foundation for extracting search results through the BiDi bridge.

- `scripts/puppeteer-google-search.mjs`
- `scripts/puppeteer-yahoo-search.mjs`

These are verification scripts and are not integrated into the CLI's discovery workflow.

## Target UX
### Discovery only
```bash
swift run swift-scraper -- \
  --discover "swift web scraping" \
  --provider yahoo \
  --allow-host swift.org \
  --allow-host developer.apple.com \
  --max-results 20 \
  --output out/discovery.json
```

### Directly from discovery to scraping
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

### Discovery with crawl state
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

## CLI design
### Discovery inputs
- `--discover <query>`
- `--provider <name>`
- `--allow-host <host>`
- `--max-results <count>`
- `--hop-depth <0-2>`
- `--max-pages <count>`
- `--max-pdfs <count>`
- `--skip-unchanged`

### Discovery output modes
- `results-only`: return discovery results only
- `scrape`: pass discovery results into a collection job and return the run manifest

## Internal model
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

## Flow from discovery to collection
1. Fetch the search-result list for the query
2. Mark URLs outside the allowlist as `rejected_allowlist`
3. Separate direct PDFs and page URLs into candidates
4. Remove duplicates
5. Use crawl state to identify `skip-unchanged` candidates
6. Select accepted candidates according to `max-pages` and `max-pdfs`
7. Keep all accepted, rejected, and skipped candidates in the run artifact
8. Pass only accepted candidates to the collection phase

## Handling direct PDFs
- Include direct PDFs in discovery targets
- Allow `parent_page_url` to be `null`
- Require `discovery_source=query|seed` for provenance
- A direct PDF may be consolidated into the same PDF document as one found through an HTML parent page

## Recommended provider implementation
### Initial phase
- Prioritize `Yahoo! JAPAN`
- Adapt the existing Node/Puppeteer probe to output JSON
- Make the Swift core responsible for decoding each provider's JSON contract

### Later phase
- Move the provider abstraction into Swift
- Formalize the Google provider

## Recommended failure reasons
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

## Recommended priority
The following order makes the `PDF first` policy concrete:

1. Direct PDF seed or discovery result
2. Explicit seed HTML page
3. PDFs found from an explicit seed page
4. Hop 1 HTML page
5. PDFs found from hop 1
6. Hop 2 HTML page
7. PDFs found from hop 2

Notes:

- This is a provisional plan that balances `PDF first` with parent-page provenance
- The implementation should document the order in which `max-pages` and `max-pdfs` are consumed

## Testing policy
### Unit tests
- Decode provider JSON
- Apply the allowlist filter
- Detect duplicates
- Classify accepted, rejected, and skipped candidates

### Integration tests
- Extract discovery results from local fixture HTML
- Connect discovery results to the scrape queue

### Manual smoke tests
- `yahoo`
- `google`

Tests that depend on live sites are not the primary focus of CI.

## Related documents
- [13. Knowledge Base Improvement Roadmap](13-knowledge-base-roadmap.md)
- [15. Knowledge Base Source Artifact Specification](15-kb-source-spec.md)
