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
    private let presentation: WebViewPresentation
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationWait: BiDiNavigationWait?
    private var activeNavigationID: String?
    private var activeNavigationURL: String?
    private var didEmitDOMContentLoaded = false
    private var didEmitLoad = false
    private var navigationTimeoutTask: Task<Void, Never>?
    private var preloadScripts: [String: String] = [:]

    var eventSink: (@Sendable (BiDiEvent) -> Void)?

    init(configuration: BiDiServerConfiguration, logger: StderrLogger) {
        self.configuration = configuration
        self.logger = logger

        let userContentController = WKUserContentController()
        Self.addBaseUserScripts(to: userContentController)

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = WebKitSupport.websiteDataStore(for: configuration.dataStoreMode)
        webConfiguration.userContentController = userContentController

        let frame = WebKitSupport.frame(for: configuration.viewport)
        let webView = WebKitSupport.makeWebView(frame: frame, configuration: webConfiguration)
        if let userAgent = configuration.customHeaders.userAgentHeaderValue {
            webView.customUserAgent = userAgent
            logger.info("BiDi custom User-Agent configured")
        }

        self.webView = webView
        self.presentation = WebViewPresentation(
            visibility: configuration.visibility,
            title: "SwiftScraper BiDi",
            frame: frame,
            webView: webView,
            visibleActivation: .activateApplication,
            hidesOnClose: true
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

        if let initialURL = configuration.initialURL {
            _ = try await load(url: initialURL, wait: .complete)
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

    func load(url: URL, wait: BiDiNavigationWait = .complete) async throws -> String {
        guard activeNavigationID == nil else {
            throw BiDiProtocolError.invalidArgument("navigation is already in progress")
        }

        try await injectCookies(for: url)

        let navigationID = UUID().uuidString
        activeNavigationID = navigationID
        activeNavigationURL = url.absoluteString
        navigationWait = wait
        didEmitDOMContentLoaded = false
        didEmitLoad = false

        logger.info("BiDi navigate: \(url.absoluteString)")
        emitBrowsingContextEvent(
            method: "browsingContext.navigationStarted",
            navigationID: navigationID,
            url: url.absoluteString
        )

        guard wait != .none else {
            beginNavigationLoad(url)
            return navigationID
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            beginNavigationLoad(url)
        }

        return navigationID
    }

    private func beginNavigationLoad(_ url: URL) {
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

        WebKitSupport.load(
            url,
            in: webView,
            timeout: configuration.timeouts.load,
            headers: configuration.customHeaders
        )
    }

    func evaluateExpression(_ expression: String, awaitPromise: Bool) async throws -> JSONValue {
        if awaitPromise {
            let result = try await callAsyncJavaScript(
                """
                \(Self.javaScriptResultWrapperSource)
                try {
                  return __swiftScraperBiDiSuccess(await (\(expression)));
                } catch (error) {
                  return __swiftScraperBiDiFailure(error);
                }
                """,
                arguments: [:]
            )
            return try unwrapJavaScriptResult(result)
        }

        let result = try await evaluateJavaScript(
            """
            (() => {
              \(Self.javaScriptResultWrapperSource)
              try {
                return __swiftScraperBiDiSuccess((\(expression)));
              } catch (error) {
                return __swiftScraperBiDiFailure(error);
              }
            })()
            """
        )
        return try unwrapJavaScriptResult(result)
    }

    func callFunction(_ declaration: String, arguments: [JSONValue], awaitPromise: Bool) async throws -> JSONValue {
        if awaitPromise {
            let result = try await callAsyncJavaScript(
                """
                \(Self.javaScriptResultWrapperSource)
                try {
                  const fn = \(declaration);
                  const unwrap = value => {
                    if (value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "value")) {
                      return value.value;
                    }
                    return value;
                  };
                  return __swiftScraperBiDiSuccess(await fn(...__bidiArguments.map(unwrap)));
                } catch (error) {
                  return __swiftScraperBiDiFailure(error);
                }
                """,
                arguments: [
                    "__bidiArguments": arguments.map(\.foundationValue),
                ]
            )
            return try unwrapJavaScriptResult(result)
        }

        let argumentsLiteral = try javascriptLiteral(arguments)
        let script = """
        (() => {
          \(Self.javaScriptResultWrapperSource)
          try {
            const fn = \(declaration);
            const args = \(argumentsLiteral);
            const unwrap = value => {
              if (value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "value")) {
                return value.value;
              }
              return value;
            };
            return __swiftScraperBiDiSuccess(fn(...args.map(unwrap)));
          } catch (error) {
            return __swiftScraperBiDiFailure(error);
          }
        })()
        """

        let result = try await evaluateJavaScript(script)
        return try unwrapJavaScriptResult(result)
    }

    private func unwrapJavaScriptResult(_ result: JSONValue) throws -> JSONValue {
        guard let object = result.objectValue,
              object["__swiftScraperBiDiResult"]?.boolValue == true,
              let ok = object["ok"]?.boolValue else {
            return result
        }

        if ok {
            return object["value"] ?? .null
        }

        let name = object["name"]?.stringValue ?? "Error"
        let message = object["message"]?.stringValue ?? ""
        let stacktrace = object["stack"]?.stringValue
        let formattedMessage = message.isEmpty ? name : "\(name): \(message)"
        throw BiDiProtocolError.javascriptError(message: formattedMessage, stacktrace: stacktrace)
    }

    private static let javaScriptResultWrapperSource = """
    const __swiftScraperBiDiSuccess = value => ({
      __swiftScraperBiDiResult: true,
      ok: true,
      value
    });
    const __swiftScraperBiDiFailure = error => ({
      __swiftScraperBiDiResult: true,
      ok: false,
      name: error && error.name ? String(error.name) : "Error",
      message: error && error.message ? String(error.message) : String(error),
      stack: error && error.stack ? String(error.stack) : ""
    });
    """

    func getHTML() async throws -> String {
        let value = try await evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
        return value.stringValue ?? ""
    }

    func getText() async throws -> String {
        let value = try await evaluateJavaScript("document.body ? document.body.innerText : ''")
        return value.stringValue ?? ""
    }

    func waitForSelector(selector: String, timeout: TimeInterval, pollInterval: TimeInterval) async throws -> BiDiScrapeWaitResult {
        let selectorLiteral = try javascriptLiteral(selector)
        return try await waitUntil(timeout: timeout, pollInterval: pollInterval, phase: "scrape.waitForSelector") {
            let value = try await self.evaluateJavaScript("document.querySelector(\(selectorLiteral)) !== null")
            return value.boolValue == true
        }
    }

    func waitForText(text: String, timeout: TimeInterval, pollInterval: TimeInterval) async throws -> BiDiScrapeWaitResult {
        let textLiteral = try javascriptLiteral(text)
        return try await waitUntil(timeout: timeout, pollInterval: pollInterval, phase: "scrape.waitForText") {
            let value = try await self.evaluateJavaScript(
                """
                (() => {
                  const textSource = document.documentElement ? (document.documentElement.innerText || "") : "";
                  return textSource.includes(\(textLiteral));
                })()
                """
            )
            return value.boolValue == true
        }
    }

    func waitForFunction(expression: String, timeout: TimeInterval, pollInterval: TimeInterval) async throws -> BiDiScrapeWaitResult {
        try await waitUntil(timeout: timeout, pollInterval: pollInterval, phase: "scrape.waitForFunction") {
            let value = try await self.evaluateExpression("Boolean(\(expression))", awaitPromise: false)
            return value.boolValue == true
        }
    }

    func waitForDOMStable(stableTime: TimeInterval, timeout: TimeInterval, pollInterval: TimeInterval) async throws -> BiDiScrapeWaitResult {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var attempts = 1
        var lastSnapshot = try await domSnapshot()
        var lastChangeDate = Date()

        while true {
            if Date().timeIntervalSince(lastChangeDate) >= stableTime {
                return BiDiScrapeWaitResult(
                    matched: true,
                    elapsedMilliseconds: Self.elapsedMilliseconds(since: start),
                    attempts: attempts
                )
            }

            try await sleepForPoll(
                pollInterval: pollInterval,
                deadline: deadline,
                phase: "scrape.waitForDOMStable",
                timeout: timeout
            )

            attempts += 1
            let snapshot = try await domSnapshot()
            if snapshot != lastSnapshot {
                lastSnapshot = snapshot
                lastChangeDate = Date()
            }
        }
    }

    func autoScroll(timeout: TimeInterval, pollInterval: TimeInterval) async throws -> BiDiScrapeAutoScrollResult {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var previousScrollHeight = -1.0
        var stableBottomCount = 0
        var steps = 0

        while true {
            let probe = try await evaluateAutoScrollProbe()
            steps += 1

            if probe.reachedBottom {
                if probe.scrollHeight == previousScrollHeight {
                    stableBottomCount += 1
                } else {
                    stableBottomCount = 0
                }

                if stableBottomCount >= 1 {
                    return BiDiScrapeAutoScrollResult(
                        scrollTop: probe.scrollTop,
                        scrollHeight: probe.scrollHeight,
                        clientHeight: probe.clientHeight,
                        reachedBottom: true,
                        steps: steps,
                        elapsedMilliseconds: Self.elapsedMilliseconds(since: start)
                    )
                }
            } else {
                stableBottomCount = 0
            }

            previousScrollHeight = probe.scrollHeight
            try await sleepForPoll(
                pollInterval: pollInterval,
                deadline: deadline,
                phase: "scrape.autoScroll",
                timeout: timeout
            )
        }
    }

    func extract(options: BiDiScrapeExtractOptions) async throws -> BiDiScrapeExtractResult {
        let rawValue = try await evaluateJavaScript(WebScraper.makeExtractionScriptForTesting(options.extraction))
        let extracted: String

        if let stringValue = rawValue.stringValue {
            if case .structureInspection = options.extraction {
                extracted = try StructureInspectionFormatter.render(json: stringValue)
            } else {
                extracted = stringValue
            }
        } else if case .null = rawValue,
                  case .selectorInnerHTML(let selector) = options.extraction {
            throw ScraperError.extractionFailed("No element matches the selector: \(selector)")
        } else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "scrape.extract",
                expected: "String"
            )
        }

        let imageResult = try await applyImageExtractionIfNeeded(
            to: extracted,
            extraction: options.extraction,
            imageExtraction: options.imageExtraction
        )
        let formatted = try OutputFormatter.format(
            imageResult.data,
            sourceURL: sourceURL(),
            extraction: options.extraction,
            outputFormat: options.outputFormat,
            prettyPrint: options.prettyPrint
        )

        return BiDiScrapeExtractResult(
            data: formatted,
            imageCandidateCount: imageResult.candidateCount,
            imageKeptCount: imageResult.keptCount,
            imageDebugJSON: imageResult.debugJSON
        )
    }

    func addPreloadScript(functionDeclaration: String) -> String {
        let scriptID = "preload-\(UUID().uuidString)"
        preloadScripts[scriptID] = functionDeclaration
        rebuildUserScripts()
        return scriptID
    }

    func removePreloadScript(scriptID: String) throws {
        guard preloadScripts.removeValue(forKey: scriptID) != nil else {
            throw BiDiProtocolError.invalidArgument("Unknown preload script: \(scriptID)")
        }

        rebuildUserScripts()
    }

    func captureScreenshot() async throws -> String {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds

        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: ScraperError.extractionFailed(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ScraperError.extractionFailed("WKWebView snapshot returned no image"))
                }
            }
        }

        guard let pngData = image.pngData else {
            throw ScraperError.extractionFailed("WKWebView snapshot could not be encoded as PNG")
        }

        return pngData.base64EncodedString()
    }

    func setViewport(width: Int, height: Int) {
        let size = NSSize(width: width, height: height)
        webView.setFrameSize(size)
        presentation.resize(to: size)
    }

    func getCookies() async -> [HTTPCookie] {
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    func setCookie(_ cookie: CookieDefinition) async throws {
        let httpCookie = try cookie.makeHTTPCookie()
        await webView.configuration.websiteDataStore.httpCookieStore.setCookieAsync(httpCookie)
    }

    func deleteCookies(matching filter: BiDiCookieFilter) async -> Int {
        let cookies = await getCookies().filter { filter.matches($0) }
        let store = webView.configuration.websiteDataStore.httpCookieStore

        for cookie in cookies {
            await store.deleteCookieAsync(cookie)
        }

        return cookies.count
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        phase: String,
        probe: @escaping @MainActor () async throws -> Bool
    ) async throws -> BiDiScrapeWaitResult {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var attempts = 0

        while true {
            attempts += 1

            if try await probe() {
                return BiDiScrapeWaitResult(
                    matched: true,
                    elapsedMilliseconds: Self.elapsedMilliseconds(since: start),
                    attempts: attempts
                )
            }

            try await sleepForPoll(
                pollInterval: pollInterval,
                deadline: deadline,
                phase: phase,
                timeout: timeout
            )
        }
    }

    private func sleepForPoll(
        pollInterval: TimeInterval,
        deadline: Date,
        phase: String,
        timeout: TimeInterval
    ) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw ScraperError.timedOut(phase: phase, timeout: timeout)
        }

        let interval = min(pollInterval, remaining)
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

        if deadline.timeIntervalSinceNow <= 0 {
            throw ScraperError.timedOut(phase: phase, timeout: timeout)
        }
    }

    private func domSnapshot() async throws -> String {
        let value = try await evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
        return value.stringValue ?? ""
    }

    private func evaluateAutoScrollProbe() async throws -> BiDiAutoScrollProbeResult {
        let value = try await evaluateJavaScript(WebScraper.makeAutoScrollScriptForTesting())
        guard let json = value.stringValue else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "scrape.autoScroll",
                expected: "JSON String"
            )
        }

        do {
            return try JSONDecoder().decode(BiDiAutoScrollProbeResult.self, from: Data(json.utf8))
        } catch {
            throw ScraperError.javaScriptFailed("scrape.autoScroll JSON decode failed: \(error.localizedDescription)")
        }
    }

    private func applyImageExtractionIfNeeded(
        to output: String,
        extraction: ExtractionMode,
        imageExtraction: ImageExtractionConfiguration
    ) async throws -> (data: String, candidateCount: Int?, keptCount: Int?, debugJSON: String?) {
        guard imageExtraction.enabled, supportsImageExtraction(extraction) else {
            return (output, nil, nil, nil)
        }

        let candidates = try await evaluateImageCandidates()
        let evaluatedImages = ImageHeuristics.evaluate(candidates, configuration: imageExtraction)
        let keptCount = evaluatedImages.filter { $0.shouldKeep(includeMaybe: imageExtraction.includeMaybe) }.count
        let debugJSON = imageExtraction.debug ? try ImageDebugFormatter.render(
            pageURL: sourceURL(),
            evaluatedImages: evaluatedImages,
            configuration: imageExtraction
        ) : nil

        let filtered = try ImageContentFilter.filter(
            output,
            sourceURL: sourceURL(),
            extraction: extraction,
            evaluatedImages: evaluatedImages,
            configuration: imageExtraction
        )

        return (filtered, evaluatedImages.count, keptCount, debugJSON)
    }

    private func evaluateImageCandidates() async throws -> [ImageCandidate] {
        let value = try await evaluateJavaScript(WebScraper.makeImageCandidateScriptForTesting())
        guard let json = value.stringValue else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "scrape.extract image collection",
                expected: "JSON String"
            )
        }

        do {
            return try JSONDecoder().decode([ImageCandidate].self, from: Data(json.utf8))
        } catch {
            throw ScraperError.javaScriptFailed("scrape.extract image JSON decode failed: \(error.localizedDescription)")
        }
    }

    private func supportsImageExtraction(_ extraction: ExtractionMode) -> Bool {
        switch extraction {
        case .outerHTML, .selectorInnerHTML, .contentOnly:
            return true
        case .bodyText, .structureInspection:
            return false
        }
    }

    private func sourceURL() -> URL {
        URL(string: currentURLString()) ?? URL(fileURLWithPath: "/")
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func rebuildUserScripts() {
        let userContentController = webView.configuration.userContentController
        userContentController.removeAllUserScripts()
        Self.addBaseUserScripts(to: userContentController)

        for scriptID in preloadScripts.keys.sorted() {
            guard let functionDeclaration = preloadScripts[scriptID] else {
                continue
            }

            userContentController.addUserScript(
                WKUserScript(
                    source: Self.preloadScriptSource(functionDeclaration),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
    }

    private func injectCookies(for url: URL) async throws {
        let cookies = configuration.cookies.filter { $0.matches(url: url) }
        guard !cookies.isEmpty else {
            logger.info("BiDi Cookie injection skipped")
            return
        }

        logger.info("BiDi Cookie injection: \(cookies.count)")
        let store = webView.configuration.websiteDataStore.httpCookieStore

        for cookie in cookies {
            let httpCookie = try cookie.makeHTTPCookie()
            await store.setCookieAsync(httpCookie)
        }
    }

    private func evaluateJavaScript(_ script: String) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            let resumeState = BiDiContinuationResumeState()
            var timeoutTask: Task<Void, Never>?

            let resumeOnce: (Result<JSONValue, Error>) -> Void = { result in
                guard resumeState.markResumed() else {
                    return
                }

                timeoutTask?.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            timeoutTask = makeJavaScriptTimeoutTask(resume: resumeOnce)

            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    resumeOnce(.failure(ScraperError.javaScriptFailed(error.localizedDescription)))
                } else {
                    resumeOnce(.success(JSONValue(webKitValue: value)))
                }
            }
        }
    }

    private func callAsyncJavaScript(_ script: String, arguments: [String: Any]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            let resumeState = BiDiContinuationResumeState()
            var timeoutTask: Task<Void, Never>?
            var evaluationTask: Task<Void, Never>?

            let resumeOnce: (Result<JSONValue, Error>) -> Void = { result in
                guard resumeState.markResumed() else {
                    return
                }

                timeoutTask?.cancel()
                evaluationTask?.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            timeoutTask = makeJavaScriptTimeoutTask(resume: resumeOnce)
            evaluationTask = Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript(
                        script,
                        arguments: arguments,
                        in: nil,
                        contentWorld: .page
                    )
                    resumeOnce(.success(JSONValue(webKitValue: value)))
                } catch {
                    resumeOnce(.failure(ScraperError.javaScriptFailed(error.localizedDescription)))
                }
            }
        }
    }

    private func makeJavaScriptTimeoutTask(resume: @escaping (Result<JSONValue, Error>) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let nanoseconds = UInt64(max(0, configuration.timeouts.javaScript) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard !Task.isCancelled else {
                return
            }

            resume(
                .failure(
                    ScraperError.timedOut(
                        phase: "BiDi JavaScript",
                        timeout: configuration.timeouts.javaScript
                    )
                )
            )
        }
    }

    private func completeNavigation(with result: Result<Void, Error>) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil

        guard activeNavigationID != nil else {
            return
        }

        let navigationID = activeNavigationID
        let requestedNavigationURL = activeNavigationURL
        let navigationURL = currentURLString()
        let continuation = navigationContinuation

        switch result {
        case .success:
            emitDOMContentLoadedIfNeeded(navigationID: navigationID, url: navigationURL)
            emitLoadIfNeeded(navigationID: navigationID, url: navigationURL)
            resetNavigationState()
            continuation?.resume()
        case .failure(let error):
            emitBrowsingContextEvent(
                method: "browsingContext.navigationFailed",
                navigationID: navigationID,
                url: requestedNavigationURL ?? navigationURL
            )
            resetNavigationState()
            continuation?.resume(throwing: error)
        }
    }

    private func emitDOMContentLoadedIfNeeded(navigationID: String?, url: String) {
        guard !didEmitDOMContentLoaded else {
            return
        }

        didEmitDOMContentLoaded = true
        emitBrowsingContextEvent(
            method: "browsingContext.domContentLoaded",
            navigationID: navigationID,
            url: url
        )
    }

    private func emitLoadIfNeeded(navigationID: String?, url: String) {
        guard !didEmitLoad else {
            return
        }

        didEmitLoad = true
        emitBrowsingContextEvent(
            method: "browsingContext.load",
            navigationID: navigationID,
            url: url
        )
    }

    private func markDOMContentLoaded(url: String) {
        guard let navigationID = activeNavigationID else {
            return
        }

        emitDOMContentLoadedIfNeeded(navigationID: navigationID, url: url)

        guard navigationWait == .interactive, let continuation = navigationContinuation else {
            return
        }

        navigationContinuation = nil
        navigationWait = nil
        continuation.resume()
    }

    private func resetNavigationState() {
        navigationContinuation = nil
        navigationWait = nil
        activeNavigationID = nil
        activeNavigationURL = nil
        didEmitDOMContentLoaded = false
        didEmitLoad = false
    }

    private func javascriptLiteral(_ value: some Encodable) throws -> String {
        try JavaScriptLiteral.encoded(value)
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

    private func handleNavigationLifecycleEvent(from body: [String: Any]) {
        guard body["event"] as? String == "domContentLoaded" else {
            return
        }

        markDOMContentLoaded(url: body["url"] as? String ?? currentURLString())
    }

    private static func addBaseUserScripts(to userContentController: WKUserContentController) {
        userContentController.addUserScript(
            WKUserScript(
                source: navigationLifecycleBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: consoleBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    private static func preloadScriptSource(_ functionDeclaration: String) -> String {
        """
        (() => {
          try {
            const fn = \(functionDeclaration);
            if (typeof fn !== "function") {
              throw new Error("Preload script functionDeclaration did not evaluate to a function");
            }
            fn();
          } catch (error) {
            try {
              console.error(
                "SwiftScraper preload script failed",
                error && error.stack ? error.stack : String(error)
              );
            } catch (_) {}
          }
        })();
        """
    }

    private static let navigationLifecycleBridgeScript = """
    (() => {
      const post = event => {
        try {
          window.webkit.messageHandlers.bidi.postMessage({
            type: "navigationLifecycle",
            event,
            url: location.href,
            timestamp: Date.now()
          });
        } catch (_) {}
      };

      if (document.readyState === "interactive" || document.readyState === "complete") {
        post("domContentLoaded");
      } else {
        document.addEventListener("DOMContentLoaded", () => post("domContentLoaded"), { once: true });
      }
    })();
    """

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

private final class BiDiContinuationResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !resumed else {
            return false
        }

        resumed = true
        return true
    }
}

struct BiDiCookieFilter: Sendable, Equatable {
    let name: String?
    let domain: String?
    let path: String?

    var isEmpty: Bool {
        name == nil && domain == nil && path == nil
    }

    func matches(_ cookie: HTTPCookie) -> Bool {
        if let name, cookie.name != name {
            return false
        }

        if let domain, cookie.domain != domain {
            return false
        }

        if let path, cookie.path != path {
            return false
        }

        return true
    }
}

private struct BiDiAutoScrollProbeResult: Decodable {
    let scrollTop: Double
    let scrollHeight: Double
    let clientHeight: Double
    let reachedBottom: Bool
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
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
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "console":
            emitConsoleEvent(from: body)
        case "navigationLifecycle":
            guard message.frameInfo.isMainFrame else {
                return
            }

            handleNavigationLifecycleEvent(from: body)
        default:
            return
        }
    }
}
