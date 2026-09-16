# 03. Rendering Wait

## Purpose
Wait for JavaScript-driven rendering to finish so that an incomplete DOM is not captured.

## Requirements
- Do not treat `didFinish` alone as proof that rendering is complete
- Combine conditional waits with a maximum wait time
- Support SPAs and pages with delayed rendering

## Implemented wait parameters
- `--wait-delay`: fixed wait after `didFinish`
- `--auto-scroll`: scroll downward to help trigger lazy loading
- `--wait-selector`: wait for a match from `document.querySelector(...)`; may be specified multiple times
- `--wait-text`: wait for a partial match in `document.documentElement.innerText`; may be specified multiple times
- `--poll-interval`: interval between condition checks; defaults to 0.5 seconds
- `--dom-stable-delay`: number of seconds the DOM must remain unchanged before completion; defaults to 0.5 seconds, and `0` disables it
- `--wait-timeout`: overall rendering wait limit; defaults to 15 seconds

## Main wait strategies
- Fixed delay
- Automatic downward scrolling
- Waiting for a specific CSS selector
- Waiting for specific text
- Repeated polling
- Waiting for DOM stability by monitoring changes to `document.documentElement.outerHTML`
- Timeout at the maximum wait duration

## Processing overview
1. Receive the navigation-completed event
2. Apply `--wait-delay` first when present
3. If `--auto-scroll` is enabled, scroll downward within the wait budget to trigger lazy loading
4. Evaluate selector and text conditions
5. If conditions are not met, check again at the `--poll-interval`
6. If `--dom-stable-delay` is enabled, monitor whether the DOM snapshot remains unchanged
7. Continue to the next stage when conditions are met or the timeout is reached

## Completion criteria
- The required rendering conditions are considered satisfied, or
- Waiting is stopped by the timeout

## Notes
- Some pages continue updating the DOM after `didFinish`
- Fixed waits, automatic scrolling, conditional waits, and DOM stability waits share the same `--wait-timeout` budget
- On pages whose DOM changes continuously, setting `--dom-stable-delay 0` and waiting only for explicit conditions can be more stable
- `--auto-scroll` affects only the document-level scroll. Separate handling may be needed for UIs with internal scroll containers
