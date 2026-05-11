import AppKit
import Foundation
import WebKit

@MainActor
final class BiDiWebViewHost: NSObject {
    static let contextID = "main"
    static let realmID = "main"

    private let configuration: BiDiServerConfiguration
    private let logger: StderrLogger
    private let webView: WKWebView
    private let presentation: BiDiWebViewPresentation
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var activeNavigationID: String?
    private var activeNavigationURL: String?
    private var navigationTimeoutTask: Task<Void, Never>?

    var eventSink: (@Sendable (BiDiEvent) -> Void)?

    init(configuration: BiDiServerConfiguration, logger: StderrLogger) {
        self.configuration = configuration
        self.logger = logger

        let dataStore: WKWebsiteDataStore
        switch configuration.dataStoreMode {
        case .ephemeral:
            dataStore = .nonPersistent()
        case .persistent:
            dataStore = .default()
        }

        let userContentController = WKUserContentController()
        userContentController.addUserScript(
            WKUserScript(
                source: Self.consoleBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = dataStore
        webConfiguration.userContentController = userContentController

        let frame = NSRect(x: 0, y: 0, width: configuration.viewport.width, height: configuration.viewport.height)
        let webView = WKWebView(frame: frame, configuration: webConfiguration)
        webView.setFrameSize(frame.size)
        if let userAgent = configuration.customHeaders.userAgentHeaderValue {
            webView.customUserAgent = userAgent
            logger.info("BiDi custom User-Agent configured")
        }

        self.webView = webView
        self.presentation = BiDiWebViewPresentation(
            visibility: configuration.visibility,
            frame: frame,
            webView: webView
        )

        super.init()

        userContentController.add(self, name: "bidi")
        self.webView.navigationDelegate = self
    }

    deinit {
        MainActor.assumeIsolated {
            navigationTimeoutTask?.cancel()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "bidi")
            webView.navigationDelegate = nil
        }
    }

    func start() async throws {
        presentation.activateIfNeeded()
        try await injectCookies()

        if let initialURL = configuration.initialURL {
            _ = try await load(url: initialURL)
        }
    }

    func stop() {
        navigationTimeoutTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        presentation.deactivate()
    }

    func currentURLString() -> String {
        webView.url?.absoluteString ?? "about:blank"
    }

    func load(url: URL) async throws -> String {
        guard navigationContinuation == nil else {
            throw BiDiProtocolError.invalidArgument("navigation is already in progress")
        }

        let navigationID = UUID().uuidString
        activeNavigationID = navigationID
        activeNavigationURL = url.absoluteString

        logger.info("BiDi navigate: \(url.absoluteString)")
        emitBrowsingContextEvent(
            method: "browsingContext.navigationStarted",
            navigationID: navigationID,
            url: url.absoluteString
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            navigationTimeoutTask = Task { @MainActor in
                let nanoseconds = UInt64(max(0, configuration.timeouts.load) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)

                guard !Task.isCancelled else {
                    return
                }

                webView.stopLoading()
                completeNavigation(
                    with: .failure(
                        ScraperError.timedOut(phase: "BiDi navigation", timeout: configuration.timeouts.load)
                    )
                )
            }

            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = configuration.timeouts.load
                for (name, value) in configuration.customHeaders {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                webView.load(request)
            }
        }

        return navigationID
    }

    func evaluateExpression(_ expression: String, awaitPromise: Bool) async throws -> JSONValue {
        if awaitPromise {
            return try await callAsyncJavaScript("return await (\(expression));", arguments: [:])
        }

        return try await evaluateJavaScript(expression)
    }

    func callFunction(_ declaration: String, arguments: [JSONValue], awaitPromise: Bool) async throws -> JSONValue {
        if awaitPromise {
            return try await callAsyncJavaScript(
                """
                const fn = \(declaration);
                const unwrap = value => {
                  if (value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "value")) {
                    return value.value;
                  }
                  return value;
                };
                return await fn(...__bidiArguments.map(unwrap));
                """,
                arguments: [
                    "__bidiArguments": arguments.map(\.foundationValue),
                ]
            )
        }

        let argumentsLiteral = try javascriptLiteral(arguments)
        let script = """
        (() => {
          const fn = \(declaration);
          const args = \(argumentsLiteral);
          const unwrap = value => {
            if (value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "value")) {
              return value.value;
            }
            return value;
          };
          return fn(...args.map(unwrap));
        })()
        """

        return try await evaluateJavaScript(script)
    }

    func getHTML() async throws -> String {
        let value = try await evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
        return value.stringValue ?? ""
    }

    func getText() async throws -> String {
        let value = try await evaluateJavaScript("document.body ? document.body.innerText : ''")
        return value.stringValue ?? ""
    }

    private func injectCookies() async throws {
        guard !configuration.cookies.isEmpty else {
            logger.info("BiDi Cookie injection skipped")
            return
        }

        logger.info("BiDi Cookie injection: \(configuration.cookies.count)")
        let store = webView.configuration.websiteDataStore.httpCookieStore

        for cookie in configuration.cookies {
            let httpCookie = try cookie.makeHTTPCookie()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(httpCookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func evaluateJavaScript(_ script: String) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: ScraperError.javaScriptFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: JSONValue(webKitValue: value))
                }
            }
        }
    }

    private func callAsyncJavaScript(_ script: String, arguments: [String: Any]) async throws -> JSONValue {
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
            return JSONValue(webKitValue: value)
        } catch {
            throw ScraperError.javaScriptFailed(error.localizedDescription)
        }
    }

    private func completeNavigation(with result: Result<Void, Error>) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil

        guard let continuation = navigationContinuation else {
            return
        }

        navigationContinuation = nil
        let navigationID = activeNavigationID
        let requestedNavigationURL = activeNavigationURL
        let navigationURL = currentURLString()
        activeNavigationID = nil
        activeNavigationURL = nil

        switch result {
        case .success:
            emitBrowsingContextEvent(
                method: "browsingContext.domContentLoaded",
                navigationID: navigationID,
                url: navigationURL
            )
            emitBrowsingContextEvent(
                method: "browsingContext.load",
                navigationID: navigationID,
                url: navigationURL
            )
            continuation.resume()
        case .failure(let error):
            emitBrowsingContextEvent(
                method: "browsingContext.navigationFailed",
                navigationID: navigationID,
                url: requestedNavigationURL ?? navigationURL
            )
            continuation.resume(throwing: error)
        }
    }

    private func javascriptLiteral(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func emitConsoleEvent(from body: [String: Any]) {
        let level = body["level"] as? String ?? "log"
        let timestamp = body["timestamp"] as? Int ?? Int(Date().timeIntervalSince1970 * 1000)
        let rawArguments = body["args"] as? [Any] ?? []
        let argumentValues = rawArguments.map { JSONValue(webKitValue: $0) }
        let text = argumentValues
            .map { value -> String in
                if case .string(let string) = value {
                    return string
                }

                return String(describing: value.foundationValue)
            }
            .joined(separator: " ")

        eventSink?(
            BiDiEvent(
                method: "log.entryAdded",
                params: [
                    "args": .array(argumentValues.map { $0.remoteValue() }),
                    "level": .string(level),
                    "source": .object([
                        "context": .string(Self.contextID),
                        "realm": .string(Self.realmID),
                    ]),
                    "text": .string(text),
                    "timestamp": .int(timestamp),
                    "type": .string("console"),
                    "url": .string(currentURLString()),
                ]
            )
        )
    }

    private func emitBrowsingContextEvent(method: String, navigationID: String?, url: String) {
        eventSink?(
            BiDiEvent(
                method: method,
                params: [
                    "context": .string(Self.contextID),
                    "navigation": navigationID.map(JSONValue.string) ?? .null,
                    "timestamp": .int(Int(Date().timeIntervalSince1970 * 1000)),
                    "url": .string(url),
                ]
            )
        )
    }

    private static let consoleBridgeScript = """
    (() => {
      const levels = ["log", "info", "warn", "error", "debug"];
      for (const level of levels) {
        const original = console[level];
        if (typeof original !== "function") {
          continue;
        }

        console[level] = function(...args) {
          try {
            window.webkit.messageHandlers.bidi.postMessage({
              type: "console",
              level,
              args: args.map(value => {
                try {
                  if (typeof value === "string") return value;
                  return JSON.stringify(value);
                } catch (_) {
                  return String(value);
                }
              }),
              url: location.href,
              timestamp: Date.now()
            });
          } catch (_) {}

          return original.apply(console, args);
        };
      }
    })();
    """
}

private extension Dictionary where Key == String, Value == String {
    var userAgentHeaderValue: String? {
        first { name, _ in
            name.caseInsensitiveCompare("User-Agent") == .orderedSame
        }?.value
    }
}

@MainActor
extension BiDiWebViewHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completeNavigation(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeNavigation(with: .failure(ScraperError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeNavigation(with: .failure(ScraperError.loadFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        completeNavigation(with: .failure(ScraperError.loadFailed("Web content process terminated")))
    }
}

@MainActor
extension BiDiWebViewHost: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bidi",
              let body = message.body as? [String: Any],
              body["type"] as? String == "console" else {
            return
        }

        emitConsoleEvent(from: body)
    }
}

@MainActor
private final class BiDiWebViewPresentation: NSObject, NSWindowDelegate {
    private let visibility: VisibilityMode
    private let window: NSWindow?

    init(visibility: VisibilityMode, frame: NSRect, webView: WKWebView) {
        self.visibility = visibility
        let createdWindow: NSWindow?

        switch visibility {
        case .windowless:
            createdWindow = nil
        case .hiddenWindow, .visibleWindow:
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "SwiftScraper BiDi"
            window.contentView = NSView(frame: frame)
            window.contentView?.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(webView)
            webView.frame = window.contentView?.bounds ?? frame
            webView.autoresizingMask = [.width, .height]
            createdWindow = window
        }

        self.window = createdWindow
        super.init()
        self.window?.delegate = self
    }

    func activateIfNeeded() {
        switch visibility {
        case .windowless:
            return
        case .hiddenWindow:
            window?.orderOut(nil)
        case .visibleWindow:
            window?.center()
            window?.level = .normal
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func deactivate() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in
            sender.orderOut(nil)
        }
        return false
    }
}
