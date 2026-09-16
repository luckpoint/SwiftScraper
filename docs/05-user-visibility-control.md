# 05. Limiting User Exposure

## Purpose
Provide an execution mode that does not draw excessive attention to scraping and does not interrupt the user's normal work.

## Requirements
- Avoid showing a window whenever possible
- Do not steal focus
- Do not interfere with user interaction
- Do not require complete invisibility

## Implemented modes
- `--visibility windowless`: keep only `WKWebView` without creating a window
- `--visibility hidden-window`: create a window but hide it with `orderOut(nil)`
- `--visibility visible-window`: show a normal window

## Priority
1. Keep the WebView without showing a window
2. Run it in a hidden window
3. Show it in a window at the back only when necessary

## Operating guidance
- In `windowless` and `hidden-window` modes, minimize behavior that makes the app the frontmost application
- Choose `visible-window` only when development inspection is more important
- Do not force the app to become active
- Do not make the window key or bring it to the front
- Avoid unnatural transparency and extreme off-screen placement

## Completion criteria
- Processing can run while minimizing its impact on the user's view and input

## Notes
- A backmost window may still be visible in Mission Control or other window-management views
- `hidden-window` does not remove every trace from OS-level window management
- The goal is to avoid interference rather than to guarantee complete concealment
