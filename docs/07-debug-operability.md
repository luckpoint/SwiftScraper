# 07. Debug Operability

## Purpose
Support easy inspection during development while keeping production execution quiet.

## Requirements
- Allow the WebView to be shown during development
- Allow cookie and DOM state to be inspected
- Allow production to switch to a mostly hidden mode

## Implemented switches
- Use `--visibility visible-window` to inspect the WebView visually
- Use `--visibility hidden-window` or `windowless` for quiet execution
- Use `--verbose` to write progress logs to `stderr`
- Use `--inspect-structure` to inspect how content candidates are selected
- Use `--image-debug` to inspect image heuristic `score`, `decision`, and `reasons` as JSON

## Mode policy
- Development mode
  - Show the WebView to inspect behavior
  - Make cookie injection and DOM extraction easier to inspect visually
- Production mode
  - Prefer hidden or non-frontmost execution
  - Minimize user exposure

## Inspection targets
- Cookie injection results
- Navigation events
- Whether rendering wait conditions were satisfied
- Selectors or text that were not reached
- DOM change detection logs
- Extracted HTML contents
- Scores and exclusion reasons for each image candidate
- Output destination
- Per-page success or failure during batch execution

## Completion criteria
- Development troubleshooting and quiet production operation can be switched within the same design

## Notes
- `--verbose` writes to standard error rather than standard output, so it remains separate from extraction output on stdout
- `--image-debug` also writes to standard error and does not pollute extracted content on stdout
- `--inspect-structure` is for tuning content detection and does not return the extracted HTML itself
- Over-prioritizing production concealment can make root-cause investigation difficult
- The initial implementation prioritizes development mode; hidden operation can be strengthened after stability is established
