# 02. Cookie Injection

## Purpose
Inject the cookies required to reproduce the target site's authentication or session state into `WKHTTPCookieStore` before loading the page.

## Requirements
- Insert arbitrary cookies before loading
- Support both individual CLI values and JSON files
- Set the domain, path, `Secure` attribute, and related fields correctly
- Start page loading only after cookie injection has completed

## Inputs
- `--cookie <spec>`
- `--cookie-file <path>`
- `--cookie-jar <path>`
- `--browser-cookies chrome|firefox`
- `--browser-profile <profile-name-or-path>`
- Cookie name
- Cookie value
- Domain
- Path
- Additional values such as expiry and `Secure` / `HttpOnly` attributes

## Implemented input formats
- `--cookie` accepts `name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true`
- `--cookie-file` accepts either a single JSON object or a JSON array
- `--cookie-jar` reads the same JSON format and saves the CookieStore contents as a JSON array after execution
- `--browser-cookies chrome|firefox` reads an existing macOS browser profile and converts cookies to `CookieDefinition` values in memory
- Chrome reads the standard macOS profile directory (`~/Library/Application Support/Google/Chrome`). `--browser-profile` accepts names such as `Default` or `Profile 1`, or a profile directory path
- Firefox resolves the standard macOS `profiles.ini` and supports both relative and absolute `Path` values. `--browser-profile` accepts a `Name` or a directory path
- Encrypted Chrome cookies are decrypted only with Chrome Safe Storage from the macOS Keychain and the tested `v10` format. Keychain denial or unsupported formats fail without exposing the value
- Browser cookies are read once per command; batch pages do not reload the database
- Firefox cookies with non-empty `originAttributes` and partitioned Chrome cookies are not loaded because they are not applied to a separate container
- `expires` is handled as an ISO 8601 string
- Explicit `--cookie` / `--cookie-file` cookies take precedence over browser cookies
- `--browser-cookies` and `--cookie-jar` cannot be used together
- `--cookie-jar` cannot be used for batch execution

The supported scope is macOS 13 or later with Chrome and Firefox. Brave, Windows/Linux profiles, and Firefox container cookies are unsupported and rejected by the CLI.

## Processing overview
1. Get `WKHTTPCookieStore` from `WKWebsiteDataStore`
2. If `--cookie-jar` is set and the file exists, load the cookie definitions
3. If `--browser-cookies` is set, read the browser database once and merge its cookie definitions with explicit cookies
4. Apply the domain, path, expiry, and secure rules for the target URL and construct the required `HTTPCookie` values
5. Inject them sequentially with `setCookie`
6. Wait for the completion callback before starting the load
7. If `--cookie-jar` is set, save the CookieStore contents back to the same file after execution

## Completion criteria
- The required cookies are reflected in the Cookie Store and loading may begin

## Notes
- Cookies with `Secure` require HTTPS
- Domain or path mismatches can prevent cookies from being sent as expected
- `--cookie-file` expects the JSON keys documented by the help output
- `--cookie-jar` is saved as a JSON array and does not preserve attributes unavailable in `CookieDefinition`, such as `SameSite`
- Cookie values are never written to logs, stdout, errors, debug JSON, or reports
- Some sites require `localStorage` or a CSRF token in addition to cookies
