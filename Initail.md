# Scraping with the Native macOS WebView
## Initial Requirements and Design Summary

## 1. Background

The target sites may include cases where a simple HTTP fetch is insufficient.
In particular, page content may be rendered dynamically by JavaScript, so the system must load the page in a browser engine and capture the DOM or HTML after JavaScript execution.

The chosen approach is to use macOS's native WebView, `WKWebView`, rather than an external browser automation framework such as Playwright.

---

## 2. Goals

The goals are:

- Load pages on macOS with the native WebView
- Inject cookies before loading when necessary
- Detect when JavaScript rendering has completed
- Capture the final page HTML, or the required DOM information or Markdown
- Operate without drawing excessive attention from the user when possible
- Avoid requiring a completely headless or completely invisible environment

---

## 3. Assumptions and Decisions

### 3.1 Do not use Playwright
Playwright is not used as the browser automation foundation.
Instead, embed `WKWebView` in the application and implement load control, cookie injection, and DOM extraction directly.

### 3.2 JavaScript rendering support is required
A simple `URLSession`-based HTML fetch may be insufficient.
Therefore, `WKWebView` is required as a real-browser-like rendering environment.

### 3.3 Complete headless operation is not an assumption
`WKWebView` is a GUI component and is not suited to completely headless execution in the same sense as Playwright or Puppeteer.
This design therefore aims to minimize user exposure rather than to reproduce a headless browser.

---

## 4. High-Level Approach

## 4.1 Selected technologies
- Language: Swift
- Platform: macOS
- Web rendering: `WKWebView`
- Cookie management: `WKWebsiteDataStore` / `WKHTTPCookieStore`
- HTML extraction: `evaluateJavaScript("document.documentElement.outerHTML")`

---

## 4.2 Basic policy
Load the target page with `WKWebView`, then execute JavaScript after loading to obtain the DOM or HTML.
When cookies are required, inject them into `WKHTTPCookieStore` before loading.

Consider user visibility in this order:

1. Do not show a window
2. If necessary, run in a hidden window
3. If still necessary, show it at the back

In other words, prioritize a configuration that does not show the WebView before considering a backmost window.

---

## 5. Requirements

## 5.1 Functional requirements

### 5.1.1 Page loading
- Load the specified URL in `WKWebView`

### 5.1.2 Cookie injection
- Insert arbitrary cookies before loading
- Set the target domain, path, `Secure` attribute, and related fields correctly
- Start loading after cookie injection completes

### 5.1.3 HTML extraction after JavaScript rendering
- Capture the DOM after page loading and JavaScript execution
- Use `document.documentElement.outerHTML` as the default extraction target
- Allow extension to extract selected elements when needed
- Allow the extracted result to be converted to Markdown

### 5.1.4 Rendering wait
- Do not treat `didFinish` alone as rendering completion
- Determine completion with a selector check, a fixed wait, polling, or another strategy when needed

---

## 5.2 Non-functional requirements

### 5.2.1 Limit user exposure
- Avoid showing a window whenever possible
- Do not steal focus
- Do not interrupt the user's work
- Do not require that the application be completely undetectable

### 5.2.2 Stability
- Handle page-load failures
- Provide timeout control
- Protect against JavaScript rendering waits that never finish

### 5.2.3 Debuggability
- Allow the WebView to be shown during development and switch to a more hidden mode in production
- Make cookie injection and DOM state inspectable

---

## 6. Implementation Overview

## 6.1 WebView handling
Create `WKWebView` and, when appropriate, use `WKWebsiteDataStore.nonPersistent()` to keep the session in memory.
For scraping, `nonPersistent()` is the default candidate because it helps avoid carrying state between runs.

Use the WebView in one of the following ways:

- Keep it in memory without attaching it to a window
- Keep it in a hidden window
- Attach it to a backmost window only when necessary

---

## 6.2 Cookie injection
Set cookies in `WKHTTPCookieStore` before loading.
Start loading the target page after the completion callback confirms that the settings are complete.

Notes:
- Domain and path values must be consistent
- Cookies with `Secure` require HTTPS
- Some sites may require `localStorage` or another authentication state in addition to cookies

---

## 6.3 HTML extraction
After page loading, execute the following with `evaluateJavaScript`:

- `document.documentElement.outerHTML`

This can be extended when needed to support:

- `document.body.innerText`
- `innerHTML` for a selected element
- Returning extracted results as an array
- Converting extracted HTML to Markdown

---

## 6.4 Rendering wait
`didFinish` is close to navigation completion, but an SPA or delayed-rendering page may still be building its DOM.
Combine wait strategies such as:

- A fixed delay
- Checking for a specific CSS selector
- Checking for specific text
- Repeated polling
- Timing out after the maximum wait duration

---

## 7. Reducing User Awareness

## 7.1 Basic policy
The requirement is not complete invisibility, but the process should be as unobtrusive as possible.

Use the following priority:

### First choice: Do not show a window
- Create `WKWebView`
- Do not display it on screen
- Keep it out of the user's view and normal interaction

This is the most natural option and has the smallest impact on user experience.

### Second choice: Use a hidden window
- Attach the WebView to a window but keep it hidden
- Do not take focus
- Do not interfere with normal interaction

This is a useful compromise when AppKit stability requires a window.

### Third choice: Run at the back
- Use a backmost window only when display is unavoidable
- The window may still be visible in Mission Control or window-management views
- A backmost window alone does not guarantee that the process is invisible

---

## 7.2 Do not steal focus
The behavior to avoid most is bringing the application to the front while the user is working.
In principle, avoid:

- Forcibly activating the application
- Making the window key or bringing it to the front
- Changing the display in a way that captures user input

Taking control of interaction is a greater UX problem than merely being visible.

---

## 7.3 Separate development and production
During early development, show the WebView to make behavior, cookies, and the DOM easy to inspect.
Only in production should the implementation add hidden, non-frontmost, or backmost behavior.

This separation balances implementation difficulty with production UX.

---

## 7.4 Do not over-conceal
Complete lack of user awareness is not required.
Avoid excessive concealment that makes the implementation unnatural or causes unstable OS behavior.

For example, avoid the following unless necessary:

- Extreme off-screen placement
- Unnatural transparent windows
- Window-order manipulation that fights the system

The primary goal is to avoid interfering with the user, rather than to erase every sign that the process exists.

---

## 8. Expected Sequence

The basic sequence from cookie injection to HTML extraction is as follows.

### 8.1 Initialization
1. Start the application
2. Create `WKWebViewConfiguration`
3. Configure `WKWebsiteDataStore`
4. Create `WKWebView`
5. Choose how to retain it for hidden operation when needed
   - No window
   - Hidden window
   - Backmost window

### 8.2 Prepare the session
6. Get `WKHTTPCookieStore`
7. Build the required cookies
8. Inject cookies with `setCookie`
9. Wait for cookie configuration to complete

### 8.3 Load the page
10. Create a `URLRequest` for the target URL
11. Load the page with `WKWebView.load(...)`
12. Receive the navigation-completed event

### 8.4 Wait for JavaScript rendering
13. Do not capture HTML immediately after `didFinish`
14. Wait until the required conditions are met
   - Fixed delay
   - Selector check
   - Polling
15. Continue when the conditions are met or the timeout is reached

### 8.5 Extract HTML
16. Execute `evaluateJavaScript("document.documentElement.outerHTML")`
17. Receive the HTML string
18. Save, analyze, or pass it to the next stage as needed

### 8.6 Finish
19. Destroy the WebView or return it to a reuse queue
20. Clear cookies or the session when necessary
21. Process the next page or finish the task

---

## 9. Design Notes

## 9.1 `didFinish` is not enough
On JavaScript-rendered sites, the DOM can continue changing after `didFinish`.
Additional logic is required to determine rendering completion.

---

## 9.2 Viewport and size dependencies
Even when using a hidden WebView, avoid setting its size to zero.
Responsive layouts, lazy loading, and visibility checks can depend on the frame size, so provide an appropriate frame.

---

## 9.3 Lazy loading and viewport visibility
Images and elements may load only after scrolling or when they become visible.
When necessary, consider supporting the process with JavaScript scrolling.

---

## 9.4 Authentication state is not limited to cookies
Depending on the site, authentication may also require:

- `localStorage`
- `sessionStorage`
- A CSRF token
- Additional XHR requests

The initial design assumes cookie support first and leaves other mechanisms for later extension if needed.

---

## 9.5 Do not target fully headless equivalence
This design accepts the constraints of `WKWebView`.
It does not aim for the reproducibility or independence of a CI-oriented headless browser.
It is a local macOS execution foundation that uses WebKit to capture HTML after JavaScript execution.

---

## 10. Initial Design Conclusion

The project adopts the following policy:

- Use macOS's native `WKWebView` instead of Playwright
- Capture HTML after JavaScript rendering
- Inject cookies before loading
- Add rendering wait conditions instead of relying only on `didFinish`
- Minimize user exposure without targeting complete invisibility
- Use this UI priority:
  **No window** → **Hidden window** → **Backmost window**
- Focus on being unobtrusive rather than guaranteeing that the process can never be noticed

---

## 11. Details for the Next Phase

The next phase should define:

- The concrete cookie injection specification
- The list of pages to extract and their completion conditions
- A wait strategy for SPAs
- Timeout and retry policies
- The concrete hidden-operation mechanism
- The switch between development and production modes
- The storage location and downstream processing for extracted HTML
