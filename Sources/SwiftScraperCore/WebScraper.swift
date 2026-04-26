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

        let dataStore: WKWebsiteDataStore
        switch configuration.dataStoreMode {
        case .ephemeral:
            dataStore = .nonPersistent()
        case .persistent:
            dataStore = .default()
        }

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = dataStore

        let frame = NSRect(x: 0, y: 0, width: configuration.viewport.width, height: configuration.viewport.height)
        let webView = WKWebView(frame: frame, configuration: webConfiguration)
        webView.setFrameSize(frame.size)
        self.webView = webView
        self.presentation = WebViewPresentation(visibility: configuration.visibility, frame: frame, webView: webView)

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
        return try await extract()
    }

    private func injectCookies() async throws {
        guard !configuration.cookies.isEmpty else {
            logger.info("Cookie 注入はありません")
            return
        }

        logger.info("Cookie を \(configuration.cookies.count) 件注入します")
        let store = webView.configuration.websiteDataStore.httpCookieStore

        for cookie in configuration.cookies {
            let httpCookie = try cookie.makeHTTPCookie()
            await setCookie(httpCookie, store: store)
            logger.info("Cookie 注入完了: \(cookie.name) @ \(cookie.domain)")
        }

        if configuration.verbose {
            let injected = await getAllCookies(from: store)
            logger.info("CookieStore 件数: \(injected.count)")
        }
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

            if configuration.url.isFileURL {
                let readAccessURL = configuration.url.deletingLastPathComponent()
                webView.loadFileURL(configuration.url, allowingReadAccessTo: readAccessURL)
            } else {
                var request = URLRequest(url: configuration.url)
                request.timeoutInterval = configuration.timeouts.load
                webView.load(request)
            }
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

            return stringValue
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
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func setCookie(_ cookie: HTTPCookie, store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private func getAllCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
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
}

private enum ExtractionScriptBuilder {
    static func makeScript(for extraction: ExtractionMode) -> String {
        switch extraction {
        case .outerHTML:
            return """
            (() => {
              if (!document.documentElement) { return ''; }
              const clone = document.documentElement.cloneNode(true);
              sanitizeClone(document.documentElement, clone);
              return clone.outerHTML;

              function sanitizeClone(originalRoot, clonedRoot) {
                clonedRoot.querySelectorAll('script, noscript').forEach(node => node.remove());

                const originalIframes = Array.from(originalRoot.querySelectorAll('iframe'));
                const clonedIframes = Array.from(clonedRoot.querySelectorAll('iframe'));

                originalIframes.forEach((iframe, index) => {
                  if (shouldRemoveIframe(iframe)) {
                    clonedIframes[index]?.remove();
                  }
                });
              }

              function shouldRemoveIframe(iframe) {
                if (iframe.hidden) { return true; }

                const style = window.getComputedStyle ? window.getComputedStyle(iframe) : null;
                if (style && (style.display === 'none' || style.visibility === 'hidden')) {
                  return true;
                }

                const rect = iframe.getBoundingClientRect ? iframe.getBoundingClientRect() : null;
                if (rect && (rect.width === 0 || rect.height === 0)) {
                  return true;
                }

                const width = Number.parseFloat(iframe.getAttribute('width') || '');
                const height = Number.parseFloat(iframe.getAttribute('height') || '');
                return (Number.isFinite(width) && width === 0) || (Number.isFinite(height) && height === 0);
              }
            })()
            """
        case .bodyText:
            return "document.body ? document.body.innerText : ''"
        case .selectorInnerHTML(let selector):
            return """
            (() => {
              const element = document.querySelector(\(javascriptStringLiteral(selector)));
              if (!element) { return null; }
              if (element.tagName && ['script', 'noscript'].includes(element.tagName.toLowerCase())) { return ''; }
              if (element.tagName && element.tagName.toLowerCase() === 'iframe' && shouldRemoveIframe(element)) { return ''; }
              const clone = element.cloneNode(true);
              sanitizeClone(element, clone);
              return clone.innerHTML;

              function sanitizeClone(originalRoot, clonedRoot) {
                clonedRoot.querySelectorAll('script, noscript').forEach(node => node.remove());

                const originalIframes = Array.from(originalRoot.querySelectorAll('iframe'));
                const clonedIframes = Array.from(clonedRoot.querySelectorAll('iframe'));

                originalIframes.forEach((iframe, index) => {
                  if (shouldRemoveIframe(iframe)) {
                    clonedIframes[index]?.remove();
                  }
                });
              }

              function shouldRemoveIframe(iframe) {
                if (iframe.hidden) { return true; }

                const style = window.getComputedStyle ? window.getComputedStyle(iframe) : null;
                if (style && (style.display === 'none' || style.visibility === 'hidden')) {
                  return true;
                }

                const rect = iframe.getBoundingClientRect ? iframe.getBoundingClientRect() : null;
                if (rect && (rect.width === 0 || rect.height === 0)) {
                  return true;
                }

                const width = Number.parseFloat(iframe.getAttribute('width') || '');
                const height = Number.parseFloat(iframe.getAttribute('height') || '');
                return (Number.isFinite(width) && width === 0) || (Number.isFinite(height) && height === 0);
              }
            })()
            """
        case .contentOnly:
            return #"""
            (() => {
              \#(pageAnalysisHelpers)
              const analysis = analyzeDocument();
              return analysis.clone ? analysis.clone.outerHTML : '';
            })()
            """#
        case .structureInspection:
            return #"""
            (() => {
              \#(pageAnalysisHelpers)
              const analysis = analyzeDocument();
              const landmarks = {
                header: document.querySelectorAll('header, [role="banner"]').length,
                footer: document.querySelectorAll('footer, [role="contentinfo"]').length,
                nav: document.querySelectorAll('nav, [role="navigation"]').length,
                aside: document.querySelectorAll('aside, [role="complementary"]').length,
                main: document.querySelectorAll('main, [role="main"]').length,
                article: document.querySelectorAll('article').length
              };

              return JSON.stringify({
                title: document.title || '',
                url: window.location ? window.location.href : '',
                landmarks,
                candidate: describeNode(analysis.node),
                candidateTextLength: analysis.textLength,
                testedCandidates: analysis.testedCandidates,
                fallbackToBody: analysis.fallbackToBody,
                contentOnlyRemoval: analysis.removedCounts
              });
            })()
            """#
        }
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static var pageAnalysisHelpers: String {
        #"""
        function analyzeDocument() {
          const candidates = collectCandidates();
          const body = document.body || null;
          if (body && !candidates.includes(body)) {
            candidates.push(body);
          }

          let best = null;

          candidates.forEach(node => {
            const clone = node.cloneNode(true);
            const removedCounts = sanitizeClone(clone);
            const textLength = normalizeWhitespace(clone.innerText || clone.textContent || '').length;
            const score = textLength + semanticWeight(node) - Math.floor(linkDensity(node) * 500);

            if (!best || score > best.score) {
              best = {
                node,
                clone,
                removedCounts,
                textLength,
                score,
                fallbackToBody: body !== null && node === body
              };
            }
          });

          if (!best) {
            return {
              node: null,
              clone: null,
              removedCounts: emptyRemovalCounts(),
              textLength: 0,
              testedCandidates: 0,
              fallbackToBody: body !== null
            };
          }

          return {
            node: best.node,
            clone: best.clone,
            removedCounts: best.removedCounts,
            textLength: best.textLength,
            testedCandidates: candidates.length,
            fallbackToBody: best.fallbackToBody
          };
        }

        function collectCandidates() {
          const selectors = [
            'main',
            '[role="main"]',
            'article',
            '#content',
            '#main',
            '.content',
            '.main',
            '.article',
            '.article-body',
            '.article-content',
            '.post-content',
            '.entry-content',
            '.content-body',
            '.page-content',
            '.story-body'
          ];
          const seen = new Set();
          const candidates = [];

          selectors.forEach(selector => {
            document.querySelectorAll(selector).forEach(node => {
              if (!seen.has(node)) {
                seen.add(node);
                candidates.push(node);
              }
            });
          });

          return candidates;
        }

        function sanitizeClone(root) {
          const counts = emptyRemovalCounts();
          walk(root);
          return counts;

          function walk(node) {
            Array.from(node.children).forEach(child => {
              if (isScriptLike(child)) {
                counts.scriptLike += 1;
                child.remove();
                return;
              }

              if (shouldRemoveNode(child)) {
                incrementRemovalCount(child, counts);
                child.remove();
                return;
              }

              walk(child);
            });
          }
        }

        function emptyRemovalCounts() {
          return {
            header: 0,
            footer: 0,
            nav: 0,
            aside: 0,
            sidebarLike: 0,
            hidden: 0,
            scriptLike: 0
          };
        }

        function shouldRemoveNode(node) {
          return isLandmarkChrome(node) || isSidebarLike(node) || isHidden(node);
        }

        function isScriptLike(node) {
          const tag = node.tagName ? node.tagName.toLowerCase() : '';
          return tag === 'script' || tag === 'noscript' || tag === 'template';
        }

        function isLandmarkChrome(node) {
          const tag = node.tagName ? node.tagName.toLowerCase() : '';
          if (tag === 'header' || tag === 'footer' || tag === 'nav' || tag === 'aside') {
            return true;
          }

          const role = (node.getAttribute('role') || '').toLowerCase();
          return role === 'banner' || role === 'contentinfo' || role === 'navigation' || role === 'complementary';
        }

        function isSidebarLike(node) {
          const tokens = nodeTokenSource(node);
          return /(^|\b)(sidebar|side-bar|sidenav|side-nav|rail|right-rail|left-rail|breadcrumbs?|share|social|related|promo|advert|ads)(\b|$)/.test(tokens);
        }

        function isHidden(node) {
          if (node.hidden) {
            return true;
          }

          const ariaHidden = (node.getAttribute('aria-hidden') || '').toLowerCase();
          if (ariaHidden === 'true') {
            return true;
          }

          const style = (node.getAttribute('style') || '').toLowerCase();
          if (style.includes('display:none') || style.includes('display: none') || style.includes('visibility:hidden') || style.includes('visibility: hidden')) {
            return true;
          }

          return /(^|\b)(hidden|sr-only|visually-hidden)(\b|$)/.test(nodeTokenSource(node));
        }

        function incrementRemovalCount(node, counts) {
          if (isLandmarkChrome(node)) {
            const tag = node.tagName ? node.tagName.toLowerCase() : '';
            const role = (node.getAttribute('role') || '').toLowerCase();

            if (tag === 'header' || role === 'banner') {
              counts.header += 1;
              return;
            }

            if (tag === 'footer' || role === 'contentinfo') {
              counts.footer += 1;
              return;
            }

            if (tag === 'nav' || role === 'navigation') {
              counts.nav += 1;
              return;
            }

            if (tag === 'aside' || role === 'complementary') {
              counts.aside += 1;
              return;
            }
          }

          if (isSidebarLike(node)) {
            counts.sidebarLike += 1;
            return;
          }

          if (isHidden(node)) {
            counts.hidden += 1;
          }
        }

        function semanticWeight(node) {
          let weight = 0;
          const tag = node.tagName ? node.tagName.toLowerCase() : '';
          const role = (node.getAttribute('role') || '').toLowerCase();
          const tokens = nodeTokenSource(node);

          if (tag === 'main') { weight += 1500; }
          if (tag === 'article') { weight += 1200; }
          if (role === 'main') { weight += 1200; }
          if (node === document.body) { weight -= 1500; }
          if (/(^|\b)(content|article|story|post|entry|main)(\b|$)/.test(tokens)) { weight += 400; }
          if (/(^|\b)(nav|menu|footer|header|sidebar)(\b|$)/.test(tokens)) { weight -= 1000; }

          return weight;
        }

        function linkDensity(node) {
          const textLength = normalizeWhitespace(node.innerText || node.textContent || '').length;
          if (textLength === 0) {
            return 0;
          }

          let linkTextLength = 0;
          node.querySelectorAll('a').forEach(anchor => {
            linkTextLength += normalizeWhitespace(anchor.innerText || anchor.textContent || '').length;
          });

          return linkTextLength / textLength;
        }

        function normalizeWhitespace(value) {
          return (value || '').replace(/\s+/g, ' ').trim();
        }

        function nodeTokenSource(node) {
          const className = typeof node.className === 'string' ? node.className : (node.getAttribute('class') || '');
          const id = node.id || '';
          const ariaLabel = node.getAttribute('aria-label') || '';
          return `${id} ${className} ${ariaLabel}`.toLowerCase();
        }

        function describeNode(node) {
          if (!node || !node.tagName) {
            return '(not found)';
          }

          const tag = node.tagName.toLowerCase();
          const id = node.id ? `#${node.id}` : '';
          const classes = Array.from(node.classList || []).slice(0, 3).map(name => `.${name}`).join('');
          return `${tag}${id}${classes}`;
        }
        """#
    }
}

@MainActor
private final class WebViewPresentation {
    private let visibility: VisibilityMode
    private let window: NSWindow?

    init(visibility: VisibilityMode, frame: NSRect, webView: WKWebView) {
        self.visibility = visibility

        switch visibility {
        case .windowless:
            self.window = nil
        case .hiddenWindow, .visibleWindow:
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "SwiftScraper"
            window.contentView = NSView(frame: frame)
            window.contentView?.addSubview(webView)
            webView.frame = window.contentView?.bounds ?? frame
            webView.autoresizingMask = [.width, .height]
            window.collectionBehavior = [.ignoresCycle, .transient]
            self.window = window
        }
    }

    func activateIfNeeded() {
        switch visibility {
        case .windowless:
            return
        case .hiddenWindow:
            window?.orderOut(nil)
        case .visibleWindow:
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func deactivate() {
        window?.orderOut(nil)
        window?.close()
    }
}
