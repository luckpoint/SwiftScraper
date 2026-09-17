import Foundation

@MainActor
final class BiDiDispatcher {
    private let host: BiDiWebViewHost
    private let parameterDecoder = BiDiParameterDecoder()

    init(host: BiDiWebViewHost) {
        self.host = host
    }

    func handle(_ request: BiDiRequest, clientSession: BiDiClientSession? = nil) async -> BiDiResponse {
        guard let id = request.id else {
            return .failure(id: -1, error: "invalid argument", message: "id is required")
        }

        do {
            switch request.method {
            case "session.status":
                return .success(
                    id: id,
                    result: [
                        "message": .string("SwiftScraper WKWebView BiDi bridge is ready"),
                        "ready": .bool(true),
                    ]
                )

            case "session.new":
                return .success(
                    id: id,
                    result: [
                        "capabilities": .object([
                            "browserName": .string("SwiftScraper"),
                            "browserVersion": .string("0"),
                            "platformName": .string("macOS"),
                            "webSocketUrl": .bool(true),
                        ]),
                        "sessionId": .string("swiftscraper"),
                    ]
                )

            case "session.end":
                return .success(id: id)

            case "session.subscribe":
                let params = try parameterDecoder.requiredParams(request.params)
                let events = try parameterDecoder.requiredStringArray(params["events"], name: "events")
                let contexts = try parameterDecoder.optionalContextSet(params["contexts"])
                clientSession?.subscribe(events: events, contexts: contexts)
                return .success(id: id)

            case "session.unsubscribe":
                let params = try parameterDecoder.requiredParams(request.params)
                let events = try parameterDecoder.requiredStringArray(params["events"], name: "events")
                let contexts = try parameterDecoder.optionalContextSet(params["contexts"])
                clientSession?.unsubscribe(events: events, contexts: contexts)
                return .success(id: id)

            case "browser.getUserContexts":
                return .success(
                    id: id,
                    result: [
                        "userContexts": .array([
                            .object([
                                "userContext": .string("default"),
                            ]),
                        ]),
                    ]
                )

            case "browser.close":
                return .success(id: id)

            case "emulation.setScreenOrientationOverride":
                return .success(id: id)

            case "browsingContext.getTree":
                try parameterDecoder.validateContext(parameterDecoder.optionalContext(from: request.params))
                return .success(
                    id: id,
                    result: [
                        "contexts": .array([
                            .object([
                                "children": .array([]),
                                "context": .string(BiDiWebViewHost.contextID),
                                "userContext": .string("default"),
                                "url": .string(host.currentURLString()),
                            ]),
                        ]),
                    ]
                )

            case "browsingContext.navigate":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                guard let urlString = params["url"]?.stringValue, let url = URL(string: urlString) else {
                    throw BiDiProtocolError.invalidArgument("url is required")
                }

                guard BiDiAccessGuard.allowsNavigation(to: url) else {
                    throw BiDiProtocolError.invalidArgument("only http, https and about URLs can be navigated")
                }

                let wait = try parameterDecoder.navigationWait(from: params["wait"])
                let navigationID = try await host.load(url: url, wait: wait)
                return .success(
                    id: id,
                    result: [
                        "navigation": .string(navigationID),
                        "url": .string(url.absoluteString),
                    ]
                )

            case "browsingContext.reload":
                let params = request.params ?? [:]
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                guard let url = URL(string: host.currentURLString()), url.scheme != "about" else {
                    throw BiDiProtocolError.invalidArgument("current context has no reloadable URL")
                }

                let wait = try parameterDecoder.navigationWait(from: params["wait"])
                let navigationID = try await host.load(url: url, wait: wait)
                return .success(
                    id: id,
                    result: [
                        "navigation": .string(navigationID),
                        "url": .string(url.absoluteString),
                    ]
                )

            case "browsingContext.captureScreenshot":
                try parameterDecoder.validateContext(parameterDecoder.optionalContext(from: request.params))
                let data = try await host.captureScreenshot()
                return .success(
                    id: id,
                    result: [
                        "data": .string(data),
                    ]
                )

            case "browsingContext.setViewport":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let viewport = try parameterDecoder.requiredObject(params["viewport"], name: "viewport")
                let width = try parameterDecoder.requiredPositiveInt(viewport["width"], name: "viewport.width")
                let height = try parameterDecoder.requiredPositiveInt(viewport["height"], name: "viewport.height")
                host.setViewport(width: width, height: height)
                return .success(id: id)

            case "script.evaluate":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateTarget(params["target"])
                guard let expression = params["expression"]?.stringValue else {
                    throw BiDiProtocolError.invalidArgument("expression is required")
                }

                let value = try await host.evaluateExpression(
                    expression,
                    awaitPromise: params["awaitPromise"]?.boolValue ?? false
                )
                return valueResponse(id: id, value: value)

            case "script.callFunction":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateTarget(params["target"])
                guard let declaration = params["functionDeclaration"]?.stringValue else {
                    throw BiDiProtocolError.invalidArgument("functionDeclaration is required")
                }

                let value = try await host.callFunction(
                    declaration,
                    arguments: params["arguments"]?.arrayValue ?? [],
                    awaitPromise: params["awaitPromise"]?.boolValue ?? false
                )
                return valueResponse(id: id, value: value)

            case "script.addPreloadScript":
                let params = try parameterDecoder.requiredParams(request.params)
                guard let functionDeclaration = params["functionDeclaration"]?.stringValue,
                      !functionDeclaration.isEmpty else {
                    throw BiDiProtocolError.invalidArgument("functionDeclaration is required")
                }
                try parameterDecoder.validateOptionalContextList(params["contexts"])
                let scriptID = host.addPreloadScript(functionDeclaration: functionDeclaration)
                return .success(
                    id: id,
                    result: [
                        "script": .string(scriptID),
                    ]
                )

            case "script.removePreloadScript":
                let params = try parameterDecoder.requiredParams(request.params)
                guard let scriptID = params["script"]?.stringValue, !scriptID.isEmpty else {
                    throw BiDiProtocolError.invalidArgument("script is required")
                }
                try host.removePreloadScript(scriptID: scriptID)
                return .success(id: id)

            case "storage.getCookies", "scrape.getCookies", "swiftScraper:scrape.getCookies":
                let cookies = await host.getCookies()
                return .success(
                    id: id,
                    result: [
                        "cookies": .array(cookies.map { cookieValue($0) }),
                    ]
                )

            case "storage.setCookie", "scrape.setCookie", "swiftScraper:scrape.setCookie":
                let params = try parameterDecoder.requiredParams(request.params)
                let cookie = try parameterDecoder.cookieDefinition(from: params, currentURL: currentURL())
                try await host.setCookie(cookie)
                return .success(id: id)

            case "storage.deleteCookies", "scrape.deleteCookies", "swiftScraper:scrape.deleteCookies":
                let params = request.params ?? [:]
                let filter = try parameterDecoder.cookieFilter(from: params)
                guard !filter.isEmpty else {
                    throw BiDiProtocolError.invalidArgument("cookie filter must include name, domain, or path")
                }

                let deleted = await host.deleteCookies(matching: filter)
                return .success(
                    id: id,
                    result: [
                        "deleted": .int(deleted),
                    ]
                )

            case "scrape.waitForSelector", "swiftScraper:scrape.waitForSelector":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let selector = try parameterDecoder.requiredString(params["selector"], name: "selector")
                let waitOptions = try parameterDecoder.scrapeWaitOptions(from: params)
                let result = try await host.waitForSelector(
                    selector: selector,
                    timeout: waitOptions.timeout,
                    pollInterval: waitOptions.pollInterval
                )
                return .success(
                    id: id,
                    result: scrapeWaitResult(result).merging(["selector": .string(selector)]) { current, _ in current }
                )

            case "scrape.waitForText", "swiftScraper:scrape.waitForText":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let text = try parameterDecoder.requiredString(params["text"], name: "text")
                let waitOptions = try parameterDecoder.scrapeWaitOptions(from: params)
                let result = try await host.waitForText(
                    text: text,
                    timeout: waitOptions.timeout,
                    pollInterval: waitOptions.pollInterval
                )
                return .success(
                    id: id,
                    result: scrapeWaitResult(result).merging(["text": .string(text)]) { current, _ in current }
                )

            case "scrape.waitForFunction", "swiftScraper:scrape.waitForFunction":
                let params = try parameterDecoder.requiredParams(request.params)
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let expression = try parameterDecoder.requiredString(params["expression"], name: "expression")
                let waitOptions = try parameterDecoder.scrapeWaitOptions(from: params)
                let result = try await host.waitForFunction(
                    expression: expression,
                    timeout: waitOptions.timeout,
                    pollInterval: waitOptions.pollInterval
                )
                return .success(
                    id: id,
                    result: scrapeWaitResult(result)
                )

            case "scrape.waitForDOMStable", "swiftScraper:scrape.waitForDOMStable":
                let params = request.params ?? [:]
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let waitOptions = try parameterDecoder.scrapeWaitOptions(from: params)
                let stableTime = try parameterDecoder.optionalMilliseconds(
                    params["stableTime"] ?? params["domStableDelay"],
                    name: "stableTime",
                    defaultValue: 0.5
                )
                let result = try await host.waitForDOMStable(
                    stableTime: stableTime,
                    timeout: waitOptions.timeout,
                    pollInterval: waitOptions.pollInterval
                )
                return .success(
                    id: id,
                    result: scrapeWaitResult(result).merging([
                        "stableTime": .int(Int(stableTime * 1000)),
                    ]) { current, _ in current }
                )

            case "scrape.autoScroll", "swiftScraper:scrape.autoScroll":
                let params = request.params ?? [:]
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let waitOptions = try parameterDecoder.scrapeWaitOptions(from: params)
                let result = try await host.autoScroll(
                    timeout: waitOptions.timeout,
                    pollInterval: waitOptions.pollInterval
                )
                return .success(id: id, result: scrapeAutoScrollResult(result))

            case "scrape.extract", "swiftScraper:scrape.extract":
                let params = request.params ?? [:]
                try parameterDecoder.validateContext(params["context"]?.stringValue)
                let options = try parameterDecoder.scrapeExtractOptions(from: params)
                let result = try await host.extract(options: options)
                return .success(id: id, result: scrapeExtractResult(result, options: options))

            case "scrape.getHTML", "swiftScraper:scrape.getHTML":
                try parameterDecoder.validateContext(parameterDecoder.optionalContext(from: request.params))
                let html = try await host.getHTML()
                return valueResponse(id: id, value: .string(html))

            case "scrape.getText", "swiftScraper:scrape.getText":
                try parameterDecoder.validateContext(parameterDecoder.optionalContext(from: request.params))
                let text = try await host.getText()
                return valueResponse(id: id, value: .string(text))

            default:
                throw BiDiProtocolError.unknownCommand("Unsupported method: \(request.method)")
            }
        } catch let error as BiDiProtocolError {
            return .failure(id: id, error: error.code, message: error.message, stacktrace: error.stacktrace)
        } catch let error as ScraperError {
            return .failure(id: id, error: error.bidiErrorCode, message: error.localizedDescription)
        } catch {
            return .failure(id: id, error: "javascript error", message: error.localizedDescription)
        }
    }

    private func valueResponse(id: Int, value: JSONValue) -> BiDiResponse {
        var result: [String: JSONValue] = [
            "realm": .string(BiDiWebViewHost.realmID),
            "result": value.remoteValue(),
        ]

        if let object = value.remoteValue().objectValue {
            result["type"] = object["type"]
            result["value"] = object["value"] ?? .null
        }

        return .success(id: id, result: result)
    }

    private func scrapeWaitResult(_ result: BiDiScrapeWaitResult) -> [String: JSONValue] {
        [
            "attempts": .int(result.attempts),
            "elapsed": .int(result.elapsedMilliseconds),
            "matched": .bool(result.matched),
        ]
    }

    private func scrapeAutoScrollResult(_ result: BiDiScrapeAutoScrollResult) -> [String: JSONValue] {
        [
            "clientHeight": .double(result.clientHeight),
            "elapsed": .int(result.elapsedMilliseconds),
            "reachedBottom": .bool(result.reachedBottom),
            "scrollHeight": .double(result.scrollHeight),
            "scrollTop": .double(result.scrollTop),
            "steps": .int(result.steps),
        ]
    }

    private func scrapeExtractResult(
        _ result: BiDiScrapeExtractResult,
        options: BiDiScrapeExtractOptions
    ) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "data": .string(result.data),
            "format": .string(outputFormatName(options.outputFormat)),
            "mode": .string(extractionModeName(options.extraction)),
        ]

        if let imageCandidateCount = result.imageCandidateCount {
            object["imageCandidateCount"] = .int(imageCandidateCount)
        }

        if let imageKeptCount = result.imageKeptCount {
            object["imageKeptCount"] = .int(imageKeptCount)
        }

        if let imageDebugJSON = result.imageDebugJSON {
            object["imageDebug"] = .string(imageDebugJSON)
        }

        return object
    }

    private func extractionModeName(_ extraction: ExtractionMode) -> String {
        switch extraction {
        case .outerHTML:
            return "outerHTML"
        case .bodyText:
            return "bodyText"
        case .selectorInnerHTML:
            return "selectorInnerHTML"
        case .contentOnly:
            return "contentOnly"
        case .structureInspection:
            return "structureInspection"
        }
    }

    private func outputFormatName(_ outputFormat: OutputFormat) -> String {
        switch outputFormat {
        case .plain:
            return "plain"
        case .markdown:
            return "markdown"
        }
    }

    private func cookieValue(_ cookie: HTTPCookie) -> JSONValue {
        var object: [String: JSONValue] = [
            "domain": .string(cookie.domain),
            "httpOnly": .bool(cookie.isHTTPOnly),
            "name": .string(cookie.name),
            "path": .string(cookie.path),
            "secure": .bool(cookie.isSecure),
            "size": .int(cookie.name.utf8.count + cookie.value.utf8.count),
            "value": .object([
                "type": .string("string"),
                "value": .string(cookie.value),
            ]),
        ]

        if let expiresDate = cookie.expiresDate {
            object["expiry"] = .int(Int(expiresDate.timeIntervalSince1970))
        }

        return .object(object)
    }

    private func currentURL() -> URL? {
        URL(string: host.currentURLString())
    }
}

private extension ScraperError {
    var bidiErrorCode: String {
        switch self {
        case .invalidArgument:
            return "invalid argument"
        case .timedOut:
            return "timeout"
        case .javaScriptFailed:
            return "javascript error"
        default:
            return "unknown error"
        }
    }
}
