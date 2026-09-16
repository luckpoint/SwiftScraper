# 01. Page Loading

## Purpose
Load the target URL on macOS with `WKWebView`, then hand control to rendering waits and HTML extraction.

## Requirements
- Load the specified URL with `WKWebView.load(_:)`
- Initialize `WKWebViewConfiguration` and `WKWebsiteDataStore`
- Allow `WKWebsiteDataStore.nonPersistent()` to be selected by default
- Maintain an appropriate frame size even when running without a visible window
- Receive load success and failure through the delegate

## Inputs
- Target URL
- WebView configuration values
- A `WKHTTPCookieStore` with injected cookies

## Processing overview
1. Create `WKWebViewConfiguration`
2. Configure `WKWebsiteDataStore`
3. Create `WKWebView` with an appropriate frame
4. Create a `URLRequest` and call `load(_:)`
5. Receive `didFinish` or a failure event

## Completion criteria
- A navigation-completed event is received and processing can move to the rendering wait stage

## Notes
- `didFinish` does not mean that final rendering is complete
- A zero-size WebView can interfere with responsive layouts and lazy loading
