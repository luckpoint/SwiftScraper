import AppKit
import Foundation
import WebKit

@MainActor
public final class WebScraper: NSObject {
    private let configuration: ScraperConfiguration
    private let logger: StderrLogger
    private let webView: WKWebView
    private let presentation: WebViewPresentation

    private var navigationContinuation: CheckedContinuation<Result<Void, ScraperError>, Never>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var javaScriptContinuation: CheckedContinuation<Result<JavaScriptValue, ScraperError>, Never>?
    private var javaScriptTimeoutTask: Task<Void, Never>?

    public init(configuration: ScraperConfiguration, logger: StderrLogger) {
        self.configuration = configuration
        self.logger = logger

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = WebKitSupport.websiteDataStore(for: configuration.dataStoreMode)

        let frame = WebKitSupport.frame(for: configuration.viewport)
        let webView = WebKitSupport.makeWebView(frame: frame, configuration: webConfiguration)
        self.webView = webView
        self.presentation = WebViewPresentation(
            visibility: configuration.visibility,
            title: "SwiftScraper",
            frame: frame,
            webView: webView,
            collectionBehavior: [.ignoresCycle, .transient]
        )

        super.init()

        self.webView.navigationDelegate = self
    }

    deinit {
        navigationTimeoutTask?.cancel()
        javaScriptTimeoutTask?.cancel()
    }

    public func run() async throws -> String {
        logger.info("開始 URL: \(configuration.url.absoluteString)")
        logger.info("DataStore: \(configuration.dataStoreMode.rawValue), visibility: \(configuration.visibility.rawValue)")

        defer {
            tearDown()
        }

        presentation.activateIfNeeded()
        try await injectCookies()
        try await loadPage()
        try await waitForRenderIfNeeded()
        let output = try await extract()
        try await saveCookieJarIfNeeded()
        return output
    }

    private func injectCookies() async throws {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        var cookies = try loadCookieJarCookiesIfNeeded()
        cookies.append(contentsOf: configuration.cookies)

        guard !cookies.isEmpty else {
            logger.info("Cookie 注入はありません")
            return
        }

        logger.info("Cookie を \(cookies.count) 件注入します")

        for cookie in cookies {
            let httpCookie = try cookie.makeHTTPCookie()
            await store.setCookieAsync(httpCookie)
            logger.info("Cookie 注入完了: \(cookie.name) @ \(cookie.domain)")
        }

        if configuration.verbose {
            let injected = await store.allCookies()
            logger.info("CookieStore 件数: \(injected.count)")
        }
    }

    private func loadCookieJarCookiesIfNeeded() throws -> [CookieDefinition] {
        guard let cookieJar = configuration.cookieJar else {
            return []
        }

        let cookies = try CookieJarStore.loadIfPresent(from: cookieJar)
        logger.info("CookieJar を \(cookies.count) 件読み込みました: \(cookieJar.path)")
        return cookies
    }

    private func saveCookieJarIfNeeded() async throws {
        guard let cookieJar = configuration.cookieJar else {
            return
        }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        try CookieJarStore.save(cookies: cookies, to: cookieJar)
        logger.info("CookieJar を \(cookies.count) 件保存しました: \(cookieJar.path)")
    }

    private func loadPage() async throws {
        logger.info("ページロードを開始します")

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, ScraperError>, Never>) in
            navigationContinuation = continuation
            navigationTimeoutTask = timeoutTask(
                seconds: configuration.timeouts.load,
                error: .timedOut(phase: "ページロード", timeout: configuration.timeouts.load)
            ) { [weak self] in
                self?.webView.stopLoading()
                self?.completeNavigation(
                    with: .failure(
                        ScraperError.timedOut(
                            phase: "ページロード",
                            timeout: self?.configuration.timeouts.load ?? 0
                        )
                    )
                )
            }

            WebKitSupport.load(
                configuration.url,
                in: webView,
                timeout: configuration.timeouts.load,
                headers: configuration.customHeaders
            )
        }

        switch result {
        case .success:
            break
        case .failure(let error):
            throw error
        }

        logger.info("ページロード完了")
    }

    private func waitForRenderIfNeeded() async throws {
        let deadline = Date().addingTimeInterval(configuration.timeouts.render)

        if configuration.wait.fixedDelay > 0 {
            logger.info("固定待機: \(configuration.wait.fixedDelay)s")
            try await sleepUntilDeadlineOrThrow(
                requested: configuration.wait.fixedDelay,
                deadline: deadline,
                phase: "描画待機"
            )
        }

        if configuration.wait.autoScrollEnabled {
            try await autoScrollToBottom(until: deadline)
        } else {
            logger.info("自動スクロールは無効です")
        }

        if configuration.wait.selectorConditions.isEmpty && configuration.wait.textConditions.isEmpty {
            logger.info("追加の描画待機条件はありません")
        } else {
            logger.info("描画待機を開始します")
            try await waitForExplicitRenderConditions(until: deadline)
        }

        if configuration.wait.domStableDelay > 0 {
            try await waitForDOMStability(until: deadline)
        } else {
            logger.info("DOM 安定待機は無効です")
        }
    }

    private func autoScrollToBottom(until deadline: Date) async throws {
        logger.info("自動スクロールを開始します")

        var previousScrollHeight = -1.0
        var stableBottomCount = 0

        while true {
            let probe = try await evaluateAutoScrollStep()

            if configuration.verbose {
                logger.info(
                    "scrollTop=\(Int(probe.scrollTop)) clientHeight=\(Int(probe.clientHeight)) scrollHeight=\(Int(probe.scrollHeight)) reachedBottom=\(probe.reachedBottom)"
                )
            }

            if probe.reachedBottom {
                if probe.scrollHeight == previousScrollHeight {
                    stableBottomCount += 1
                } else {
                    stableBottomCount = 0
                }

                if stableBottomCount >= 1 {
                    logger.info("自動スクロールが完了しました")
                    try await sleepUntilDeadlineOrThrow(
                        requested: configuration.wait.pollInterval,
                        deadline: deadline,
                        phase: "描画待機"
                    )
                    return
                }
            } else {
                stableBottomCount = 0
            }

            previousScrollHeight = probe.scrollHeight

            try await sleepUntilDeadlineOrThrow(
                requested: configuration.wait.pollInterval,
                deadline: deadline,
                phase: "描画待機"
            )
        }
    }

    private func waitForExplicitRenderConditions(until deadline: Date) async throws {
        while true {
            let probe = try await evaluateWaitConditions()
            if probe.ready {
                logger.info("描画待機条件を満たしました")
                return
            }

            if configuration.verbose {
                let selectorFailures = probe.selectors.filter { !$0.matched }.map(\.value)
                let textFailures = probe.texts.filter { !$0.matched }.map(\.value)

                if !selectorFailures.isEmpty {
                    logger.info("未到達セレクタ: \(selectorFailures.joined(separator: ", "))")
                }

                if !textFailures.isEmpty {
                    logger.info("未到達テキスト: \(textFailures.joined(separator: ", "))")
                }
            }

            try await sleepUntilDeadlineOrThrow(
                requested: configuration.wait.pollInterval,
                deadline: deadline,
                phase: "描画待機"
            )
        }
    }

    private func waitForDOMStability(until deadline: Date) async throws {
        logger.info("DOM 安定待機を開始します: \(configuration.wait.domStableDelay)s")

        var lastSnapshot = try await evaluateDOMSnapshot()
        var lastChangeDate = Date()

        while true {
            if Date().timeIntervalSince(lastChangeDate) >= configuration.wait.domStableDelay {
                logger.info("DOM が安定しました")
                return
            }

            try await sleepUntilDeadlineOrThrow(
                requested: configuration.wait.pollInterval,
                deadline: deadline,
                phase: "描画待機"
            )

            let snapshot = try await evaluateDOMSnapshot()
            if snapshot != lastSnapshot {
                lastSnapshot = snapshot
                lastChangeDate = Date()

                if configuration.verbose {
                    logger.info("DOM 変化を検知しました")
                }
            }
        }
    }

    private func extract() async throws -> String {
        logger.info("抽出処理を開始します")

        let script: String
        let phase: String

        switch configuration.extraction {
        case .outerHTML:
            phase = "HTML 抽出"
            script = makeSanitizedExtractionScript(for: .outerHTML)
        case .bodyText:
            phase = "body.innerText 抽出"
            script = makeSanitizedExtractionScript(for: .bodyText)
        case .selectorInnerHTML(let selector):
            phase = "selector innerHTML 抽出"
            script = makeSanitizedExtractionScript(for: .selectorInnerHTML(selector))
        case .contentOnly:
            phase = "本文 HTML 抽出"
            script = makeSanitizedExtractionScript(for: .contentOnly)
        case .structureInspection:
            phase = "構成確認"
            script = makeSanitizedExtractionScript(for: .structureInspection)
        }

        let value = try await evaluateJavaScript(script, phase: phase)

        switch value {
        case .string(let stringValue):
            logger.info("抽出完了")
            if case .structureInspection = configuration.extraction {
                return try StructureInspectionFormatter.render(json: stringValue)
            }

            return try await applyImageExtractionIfNeeded(to: stringValue)
        case .null:
            if case .selectorInnerHTML(let selector) = configuration.extraction {
                throw ScraperError.extractionFailed("セレクタに一致する要素が見つかりません: \(selector)")
            }

            throw ScraperError.unexpectedJavaScriptResult(
                phase: phase,
                expected: "String"
            )
        }
    }

    private func applyImageExtractionIfNeeded(to output: String) async throws -> String {
        guard configuration.imageExtraction.enabled else {
            return output
        }

        guard supportsImageExtraction(configuration.extraction) else {
            return output
        }

        logger.info("画像候補の収集を開始します")
        let candidates = try await evaluateImageCandidates()
        let evaluatedImages = ImageHeuristics.evaluate(candidates, configuration: configuration.imageExtraction)
        let keptCount = evaluatedImages.filter { $0.shouldKeep(includeMaybe: configuration.imageExtraction.includeMaybe) }.count

        if configuration.imageExtraction.debug {
            let debugJSON = try ImageDebugFormatter.render(
                pageURL: configuration.url,
                evaluatedImages: evaluatedImages,
                configuration: configuration.imageExtraction
            )
            logger.raw(debugJSON)
        }

        logger.info("画像候補を \(evaluatedImages.count) 件評価し、\(keptCount) 件を残します")
        return try ImageContentFilter.filter(
            output,
            sourceURL: configuration.url,
            extraction: configuration.extraction,
            evaluatedImages: evaluatedImages,
            configuration: configuration.imageExtraction
        )
    }

    private func evaluateImageCandidates() async throws -> [ImageCandidate] {
        let rawValue = try await evaluateJavaScript(Self.makeImageCandidateScript(), phase: "画像候補収集")
        guard case .string(let json) = rawValue else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "画像候補収集",
                expected: "JSON String"
            )
        }

        do {
            return try JSONDecoder().decode([ImageCandidate].self, from: Data(json.utf8))
        } catch {
            throw ScraperError.javaScriptFailed("画像候補 JSON の解釈に失敗しました: \(error.localizedDescription)")
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

    private func evaluateWaitConditions() async throws -> RenderProbeResult {
        let selectorList = configuration.wait.selectorConditions.map(javascriptStringLiteral).joined(separator: ", ")
        let textList = configuration.wait.textConditions.map(javascriptStringLiteral).joined(separator: ", ")

        let script = """
        (() => {
          const selectors = [\(selectorList)];
          const texts = [\(textList)];
          const textSource = document.documentElement ? (document.documentElement.innerText || "") : "";
          const selectorStates = selectors.map(value => ({ value, matched: document.querySelector(value) !== null }));
          const textStates = texts.map(value => ({ value, matched: textSource.includes(value) }));
          const ready = selectorStates.every(item => item.matched) && textStates.every(item => item.matched);
          return JSON.stringify({ ready, selectors: selectorStates, texts: textStates });
        })()
        """

        let rawValue = try await evaluateJavaScript(script, phase: "描画待機条件評価")
        guard case .string(let json) = rawValue else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "描画待機条件評価",
                expected: "JSON String"
            )
        }

        do {
            return try JSONDecoder().decode(RenderProbeResult.self, from: Data(json.utf8))
        } catch {
            throw ScraperError.javaScriptFailed("待機条件評価の JSON 解釈に失敗しました: \(error.localizedDescription)")
        }
    }

    private func evaluateAutoScrollStep() async throws -> AutoScrollProbeResult {
        let rawValue = try await evaluateJavaScript(Self.makeAutoScrollScript(), phase: "自動スクロール")
        guard case .string(let json) = rawValue else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "自動スクロール",
                expected: "JSON String"
            )
        }

        do {
            return try JSONDecoder().decode(AutoScrollProbeResult.self, from: Data(json.utf8))
        } catch {
            throw ScraperError.javaScriptFailed("自動スクロール結果の JSON 解釈に失敗しました: \(error.localizedDescription)")
        }
    }

    private func evaluateDOMSnapshot() async throws -> String {
        let rawValue = try await evaluateJavaScript(
            "document.documentElement ? document.documentElement.outerHTML : ''",
            phase: "DOM 安定確認"
        )

        guard case .string(let snapshot) = rawValue else {
            throw ScraperError.unexpectedJavaScriptResult(
                phase: "DOM 安定確認",
                expected: "String"
            )
        }

        return snapshot
    }

    private func makeSanitizedExtractionScript(for extraction: ExtractionMode) -> String {
        ExtractionScriptBuilder.makeScript(for: extraction)
    }

    private func evaluateJavaScript(_ script: String, phase: String) async throws -> JavaScriptValue {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<JavaScriptValue, ScraperError>, Never>) in
            javaScriptContinuation = continuation
            javaScriptTimeoutTask = timeoutTask(
                seconds: configuration.timeouts.javaScript,
                error: .timedOut(phase: phase, timeout: configuration.timeouts.javaScript)
            ) { [weak self] in
                self?.completeJavaScript(
                    with: .failure(
                        ScraperError.timedOut(
                            phase: phase,
                            timeout: self?.configuration.timeouts.javaScript ?? 0
                        )
                    )
                )
            }

            webView.evaluateJavaScript(script) { [weak self] value, error in
                guard let self else {
                    return
                }

                if let error {
                    self.completeJavaScript(
                        with: .failure(
                            ScraperError.javaScriptFailed("\(phase): \(error.localizedDescription)")
                        )
                    )
                } else if let stringValue = value as? String {
                    self.completeJavaScript(with: .success(.string(stringValue)))
                } else if value == nil || value is NSNull {
                    self.completeJavaScript(with: .success(.null))
                } else {
                    self.completeJavaScript(
                        with: .failure(
                            ScraperError.unexpectedJavaScriptResult(
                                phase: phase,
                                expected: "String or null"
                            )
                        )
                    )
                }
            }
        }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    private func completeNavigation(with result: Result<Void, ScraperError>) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil

        guard let continuation = navigationContinuation else {
            return
        }

        navigationContinuation = nil
        continuation.resume(returning: result)
    }

    private func completeJavaScript(with result: Result<JavaScriptValue, ScraperError>) {
        javaScriptTimeoutTask?.cancel()
        javaScriptTimeoutTask = nil

        guard let continuation = javaScriptContinuation else {
            return
        }

        javaScriptContinuation = nil
        continuation.resume(returning: result)
    }

    private func timeoutTask(
        seconds: TimeInterval,
        error: ScraperError,
        operation: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard !Task.isCancelled else {
                return
            }

            logger.info("タイムアウト: \(error.localizedDescription)")
            operation()
        }
    }

    private func sleepUntilDeadlineOrThrow(requested: TimeInterval, deadline: Date, phase: String) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw ScraperError.timedOut(phase: phase, timeout: configuration.timeouts.render)
        }

        let interval = min(requested, remaining)
        let nanoseconds = UInt64(interval * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)

        if deadline.timeIntervalSinceNow <= 0 {
            throw ScraperError.timedOut(phase: phase, timeout: configuration.timeouts.render)
        }
    }

    private func tearDown() {
        navigationTimeoutTask?.cancel()
        javaScriptTimeoutTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        presentation.deactivate()
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        JavaScriptLiteral.string(value)
    }
}

@MainActor
extension WebScraper: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logger.info("didStartProvisionalNavigation")
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logger.info("didCommit")
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("didFinish")
        completeNavigation(with: .success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeNavigation(with: .failure(ScraperError.loadFailed(error.localizedDescription)))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeNavigation(with: .failure(ScraperError.loadFailed(error.localizedDescription)))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        completeNavigation(with: .failure(ScraperError.loadFailed("Web content process terminated")))
    }
}

private struct RenderProbeResult: Decodable {
    let ready: Bool
    let selectors: [RenderConditionResult]
    let texts: [RenderConditionResult]
}

private struct AutoScrollProbeResult: Decodable {
    let scrollTop: Double
    let scrollHeight: Double
    let clientHeight: Double
    let reachedBottom: Bool
}

private struct RenderConditionResult: Decodable {
    let value: String
    let matched: Bool
}

private enum JavaScriptValue: Sendable {
    case string(String)
    case null
}

extension WebScraper {
    nonisolated static func makeExtractionScriptForTesting(_ extraction: ExtractionMode) -> String {
        ExtractionScriptBuilder.makeScript(for: extraction)
    }

    nonisolated static func makeImageCandidateScriptForTesting() -> String {
        makeImageCandidateScript()
    }

    nonisolated static func makeAutoScrollScriptForTesting() -> String {
        makeAutoScrollScript()
    }

    nonisolated private static func makeAutoScrollScript() -> String {
        """
        (() => {
          const root = document.scrollingElement || document.documentElement || document.body;
          const viewportHeight = Math.max(
            window.innerHeight || 0,
            document.documentElement ? (document.documentElement.clientHeight || 0) : 0,
            document.body ? (document.body.clientHeight || 0) : 0,
            root ? (root.clientHeight || 0) : 0
          );

          if (!root || viewportHeight <= 0) {
            return JSON.stringify({ scrollTop: 0, scrollHeight: 0, clientHeight: viewportHeight, reachedBottom: true });
          }

          const scrollHeight = Math.max(
            root.scrollHeight || 0,
            document.documentElement ? (document.documentElement.scrollHeight || 0) : 0,
            document.body ? (document.body.scrollHeight || 0) : 0
          );
          const currentTop = Math.max(window.scrollY || 0, root.scrollTop || 0);
          const maxScrollTop = Math.max(scrollHeight - viewportHeight, 0);
          const nextTop = Math.min(currentTop + viewportHeight, maxScrollTop);

          window.scrollTo(0, nextTop);
          root.scrollTop = nextTop;

          const finalTop = Math.max(window.scrollY || 0, root.scrollTop || 0);
          const reachedBottom = finalTop + viewportHeight >= scrollHeight - 2;

          return JSON.stringify({
            scrollTop: finalTop,
            scrollHeight,
            clientHeight: viewportHeight,
            reachedBottom
          });
        })()
        """
    }

    nonisolated private static func makeImageCandidateScript() -> String {
        ImageCandidateScriptBuilder.makeScript()
    }
}
