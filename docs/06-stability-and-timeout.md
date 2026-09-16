# 06. Stability and Timeout Control

## Purpose
Reduce operational risks such as page-load failures, waits that never finish, and session contamination, and provide a foundation that tolerates repeated execution.

## Requirements
- Handle page-load failures
- Provide timeout control
- Protect against JavaScript rendering waits that never finish
- Allow sessions to be discarded or reused when appropriate

## Implemented timeouts
- `--load-timeout`: page-loading stage; defaults to 30 seconds
- `--wait-timeout`: overall rendering wait; defaults to 15 seconds
- `--js-timeout`: all `evaluateJavaScript` calls; defaults to 10 seconds

## Stabilization policy
- By default, use `WKWebsiteDataStore.nonPersistent()` to limit state carryover
- Define separate failure handling for loading, waiting, and extraction
- Keep fixed waits, conditional waits, and DOM stability waits within the same `--wait-timeout`
- Apply `--js-timeout` to wait-condition evaluation, DOM stability checks, and final extraction
- Treat exceeding the maximum wait as an explicit timeout
- At the end, destroy the WebView or return it to a reuse queue

## Failure cases
- URL loading failure
- Cookie injection failure
- Timeout while waiting for a selector
- Timeout while waiting for DOM stability
- JavaScript execution failure

## Completion criteria
- Success and failure paths are distinct and a result can be returned to the caller

## Notes
- Reproducing authentication state may require more than cookies
- `--persistent-store` makes session reuse easier but makes state contamination harder to isolate
- An overly long `--wait-delay` can consume the budget available for explicit condition checks and DOM stability waits
- The retry policy should be refined in a later phase based on the target site's behavior
