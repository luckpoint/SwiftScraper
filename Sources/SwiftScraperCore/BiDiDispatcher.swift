import Foundation

@MainActor
final class BiDiDispatcher {
    private let host: BiDiWebViewHost

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
                let params = try requiredParams(request.params)
                let events = try requiredStringArray(params["events"], name: "events")
                let contexts = try optionalContextSet(params["contexts"])
                clientSession?.subscribe(events: events, contexts: contexts)
                return .success(id: id)

            case "session.unsubscribe":
                let params = try requiredParams(request.params)
                let events = try requiredStringArray(params["events"], name: "events")
                let contexts = try optionalContextSet(params["contexts"])
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
                try validateContext(optionalContext(from: request.params))
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
                let params = try requiredParams(request.params)
                try validateContext(params["context"]?.stringValue)
                guard let urlString = params["url"]?.stringValue, let url = URL(string: urlString) else {
                    throw BiDiProtocolError.invalidArgument("url is required")
                }

                let wait = try navigationWait(from: params["wait"])
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
                try validateContext(params["context"]?.stringValue)
                guard let url = URL(string: host.currentURLString()), url.scheme != "about" else {
                    throw BiDiProtocolError.invalidArgument("current context has no reloadable URL")
                }

                let wait = try navigationWait(from: params["wait"])
                let navigationID = try await host.load(url: url, wait: wait)
                return .success(
                    id: id,
                    result: [
                        "navigation": .string(navigationID),
                        "url": .string(url.absoluteString),
                    ]
                )

            case "browsingContext.captureScreenshot":
                try validateContext(optionalContext(from: request.params))
                let data = try await host.captureScreenshot()
                return .success(
                    id: id,
                    result: [
                        "data": .string(data),
                    ]
                )

            case "browsingContext.setViewport":
                let params = try requiredParams(request.params)
                try validateContext(params["context"]?.stringValue)
                let viewport = try requiredObject(params["viewport"], name: "viewport")
                let width = try requiredPositiveInt(viewport["width"], name: "viewport.width")
                let height = try requiredPositiveInt(viewport["height"], name: "viewport.height")
                host.setViewport(width: width, height: height)
                return .success(id: id)

            case "script.evaluate":
                let params = try requiredParams(request.params)
                try validateTarget(params["target"])
                guard let expression = params["expression"]?.stringValue else {
                    throw BiDiProtocolError.invalidArgument("expression is required")
                }

                let value = try await host.evaluateExpression(
                    expression,
                    awaitPromise: params["awaitPromise"]?.boolValue ?? false
                )
                return valueResponse(id: id, value: value)

            case "script.callFunction":
                let params = try requiredParams(request.params)
                try validateTarget(params["target"])
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
                let params = try requiredParams(request.params)
                guard let functionDeclaration = params["functionDeclaration"]?.stringValue,
                      !functionDeclaration.isEmpty else {
                    throw BiDiProtocolError.invalidArgument("functionDeclaration is required")
                }
                try validateOptionalContextList(params["contexts"])
                let scriptID = host.addPreloadScript(functionDeclaration: functionDeclaration)
                return .success(
                    id: id,
                    result: [
                        "script": .string(scriptID),
                    ]
                )

            case "script.removePreloadScript":
                let params = try requiredParams(request.params)
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
                let params = try requiredParams(request.params)
                let cookie = try cookieDefinition(from: params)
                try await host.setCookie(cookie)
                return .success(id: id)

            case "storage.deleteCookies", "scrape.deleteCookies", "swiftScraper:scrape.deleteCookies":
                let params = request.params ?? [:]
                let filter = try cookieFilter(from: params)
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
                let params = try requiredParams(request.params)
                try validateContext(params["context"]?.stringValue)
                let selector = try requiredString(params["selector"], name: "selector")
                let waitOptions = try scrapeWaitOptions(from: params)
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
                let params = try requiredParams(request.params)
                try validateContext(params["context"]?.stringValue)
                let text = try requiredString(params["text"], name: "text")
                let waitOptions = try scrapeWaitOptions(from: params)
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
                let params = try requiredParams(request.params)
                try validateContext(params["context"]?.stringValue)
                let expression = try requiredString(params["expression"], name: "expression")
                let waitOptions = try scrapeWaitOptions(from: params)
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
                try validateContext(params["context"]?.stringValue)
                let waitOptions = try scrapeWaitOptions(from: params)
                let stableTime = try optionalMilliseconds(
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
                try validateContext(params["context"]?.stringValue)
                let waitOptions = try scrapeWaitOptions(from: params)
                let result = try await host.autoScroll(
                    timeout: waitOptions.timeout,
                    pollInterval: waitOptions.pollInterval
                )
                return .success(id: id, result: scrapeAutoScrollResult(result))

            case "scrape.extract", "swiftScraper:scrape.extract":
                let params = request.params ?? [:]
                try validateContext(params["context"]?.stringValue)
                let options = try scrapeExtractOptions(from: params)
                let result = try await host.extract(options: options)
                return .success(id: id, result: scrapeExtractResult(result, options: options))

            case "scrape.getHTML", "swiftScraper:scrape.getHTML":
                try validateContext(optionalContext(from: request.params))
                let html = try await host.getHTML()
                return valueResponse(id: id, value: .string(html))

            case "scrape.getText", "swiftScraper:scrape.getText":
                try validateContext(optionalContext(from: request.params))
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

    private func requiredParams(_ params: [String: JSONValue]?) throws -> [String: JSONValue] {
        guard let params else {
            throw BiDiProtocolError.invalidArgument("params is required")
        }

        return params
    }

    private func requiredStringArray(_ value: JSONValue?, name: String) throws -> [String] {
        guard let values = value?.arrayValue, !values.isEmpty else {
            throw BiDiProtocolError.invalidArgument("\(name) must be a non-empty array")
        }

        return try values.map { value in
            guard let string = value.stringValue, !string.isEmpty else {
                throw BiDiProtocolError.invalidArgument("\(name) must contain non-empty strings")
            }

            return string
        }
    }

    private func requiredObject(_ value: JSONValue?, name: String) throws -> [String: JSONValue] {
        guard let object = value?.objectValue else {
            throw BiDiProtocolError.invalidArgument("\(name) must be an object")
        }

        return object
    }

    private func requiredPositiveInt(_ value: JSONValue?, name: String) throws -> Int {
        guard let intValue = value?.intValue, intValue > 0 else {
            throw BiDiProtocolError.invalidArgument("\(name) must be a positive integer")
        }

        return intValue
    }

    private func optionalContextSet(_ value: JSONValue?) throws -> Set<String>? {
        guard let value else {
            return nil
        }

        guard let contexts = value.arrayValue, !contexts.isEmpty else {
            throw BiDiProtocolError.invalidArgument("contexts must be a non-empty array")
        }

        let strings = try contexts.map { value in
            guard let context = value.stringValue, !context.isEmpty else {
                throw BiDiProtocolError.invalidArgument("contexts must contain non-empty strings")
            }

            try validateContext(context)
            return context
        }

        return Set(strings)
    }

    private func validateOptionalContextList(_ value: JSONValue?) throws {
        _ = try optionalContextSet(value)
    }

    private func navigationWait(from value: JSONValue?) throws -> BiDiNavigationWait {
        guard let value else {
            return .complete
        }

        guard let rawValue = value.stringValue, let wait = BiDiNavigationWait(rawValue: rawValue) else {
            throw BiDiProtocolError.invalidArgument("wait must be one of none, interactive, complete")
        }

        return wait
    }

    private func scrapeWaitOptions(from params: [String: JSONValue]) throws -> (timeout: TimeInterval, pollInterval: TimeInterval) {
        let timeout = try optionalMilliseconds(
            params["timeout"],
            name: "timeout",
            defaultValue: 10
        )
        let pollInterval = try optionalMilliseconds(
            params["polling"] ?? params["pollInterval"],
            name: "polling",
            defaultValue: 0.25
        )

        return (timeout, pollInterval)
    }

    private func optionalMilliseconds(_ value: JSONValue?, name: String, defaultValue: TimeInterval) throws -> TimeInterval {
        guard let value else {
            return defaultValue
        }

        guard let milliseconds = value.doubleValue, milliseconds > 0 else {
            throw BiDiProtocolError.invalidArgument("\(name) must be a positive number of milliseconds")
        }

        return milliseconds / 1000
    }

    private func optionalUnitInterval(_ value: JSONValue?, name: String, defaultValue: Double) throws -> Double {
        guard let value else {
            return defaultValue
        }

        guard let number = value.doubleValue, number >= 0, number <= 1 else {
            throw BiDiProtocolError.invalidArgument("\(name) must be between 0 and 1")
        }

        return number
    }

    private func scrapeExtractOptions(from params: [String: JSONValue]) throws -> BiDiScrapeExtractOptions {
        let extraction = try extractionMode(from: params)
        let outputFormat = try outputFormat(from: params["format"])
        let prettyPrint = params["prettyPrint"]?.boolValue ?? false
        let imageExtraction = try imageExtractionConfiguration(from: params)

        return BiDiScrapeExtractOptions(
            extraction: extraction,
            outputFormat: outputFormat,
            prettyPrint: prettyPrint,
            imageExtraction: imageExtraction
        )
    }

    private func extractionMode(from params: [String: JSONValue]) throws -> ExtractionMode {
        let mode = params["mode"]?.stringValue ?? "outerHTML"

        switch mode {
        case "outerHTML", "html":
            return .outerHTML
        case "bodyText", "text":
            return .bodyText
        case "selectorInnerHTML", "selector":
            return .selectorInnerHTML(try requiredString(params["selector"], name: "selector"))
        case "contentOnly":
            return .contentOnly
        case "structureInspection":
            return .structureInspection
        default:
            throw BiDiProtocolError.invalidArgument(
                "mode must be one of outerHTML, bodyText, selectorInnerHTML, contentOnly, structureInspection"
            )
        }
    }

    private func outputFormat(from value: JSONValue?) throws -> OutputFormat {
        guard let rawValue = value?.stringValue else {
            return .plain
        }

        switch rawValue {
        case "plain":
            return .plain
        case "markdown":
            return .markdown
        default:
            throw BiDiProtocolError.invalidArgument("format must be one of plain, markdown")
        }
    }

    private func imageExtractionConfiguration(from params: [String: JSONValue]) throws -> ImageExtractionConfiguration {
        let enabled = params["extractImages"]?.boolValue ?? false
        let filter = try imageFilterMode(from: params["imageFilter"])
        let scoreThreshold = try optionalUnitInterval(
            params["imageScoreThreshold"],
            name: "imageScoreThreshold",
            defaultValue: ImageExtractionConfiguration.disabled.scoreThreshold
        )

        return ImageExtractionConfiguration(
            enabled: enabled,
            filter: filter,
            scoreThreshold: scoreThreshold,
            includeMaybe: params["imageIncludeMaybe"]?.boolValue ?? params["includeMaybe"]?.boolValue ?? false,
            debug: params["imageDebug"]?.boolValue ?? false
        )
    }

    private func imageFilterMode(from value: JSONValue?) throws -> ImageFilterMode {
        guard let rawValue = value?.stringValue else {
            return .all
        }

        guard let mode = ImageFilterMode(rawValue: rawValue) else {
            throw BiDiProtocolError.invalidArgument("imageFilter must be one of all, article-only")
        }

        return mode
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

    private func cookieDefinition(from params: [String: JSONValue]) throws -> CookieDefinition {
        let object = params["cookie"]?.objectValue ?? params
        let name = try requiredString(object["name"], name: "cookie.name")
        let value = try cookieValueString(object["value"])
        let domain = try cookieDomain(from: object)
        let path = object["path"]?.stringValue ?? "/"
        let secure = object["secure"]?.boolValue ?? (currentURL()?.scheme == "https")
        let httpOnly = object["httpOnly"]?.boolValue ?? object["http_only"]?.boolValue ?? false
        let expires = cookieExpiry(from: object["expiry"] ?? object["expires"])

        return CookieDefinition(
            name: name,
            value: value,
            domain: domain,
            path: path,
            secure: secure,
            httpOnly: httpOnly,
            expires: expires
        )
    }

    private func cookieFilter(from params: [String: JSONValue]) throws -> BiDiCookieFilter {
        let object = params["filter"]?.objectValue ?? params
        return BiDiCookieFilter(
            name: object["name"]?.stringValue,
            domain: object["domain"]?.stringValue,
            path: object["path"]?.stringValue
        )
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

    private func requiredString(_ value: JSONValue?, name: String) throws -> String {
        guard let string = value?.stringValue, !string.isEmpty else {
            throw BiDiProtocolError.invalidArgument("\(name) is required")
        }

        return string
    }

    private func cookieValueString(_ value: JSONValue?) throws -> String {
        if let string = value?.stringValue {
            return string
        }

        if let object = value?.objectValue,
           object["type"]?.stringValue == "string",
           let string = object["value"]?.stringValue {
            return string
        }

        throw BiDiProtocolError.invalidArgument("cookie.value is required")
    }

    private func cookieDomain(from object: [String: JSONValue]) throws -> String {
        if let domain = object["domain"]?.stringValue, !domain.isEmpty {
            return domain
        }

        if let host = currentURL()?.host, !host.isEmpty {
            return host
        }

        throw BiDiProtocolError.invalidArgument("cookie.domain is required when current URL has no host")
    }

    private func cookieExpiry(from value: JSONValue?) -> Date? {
        guard let seconds = value?.doubleValue else {
            return nil
        }

        return Date(timeIntervalSince1970: seconds)
    }

    private func currentURL() -> URL? {
        URL(string: host.currentURLString())
    }

    private func validateTarget(_ target: JSONValue?) throws {
        guard let target else {
            return
        }

        guard let object = target.objectValue else {
            throw BiDiProtocolError.invalidArgument("target must be an object")
        }

        try validateContext(object["context"]?.stringValue)
    }

    private func optionalContext(from params: [String: JSONValue]?) -> String? {
        guard let params else {
            return nil
        }

        if let context = params["context"]?.stringValue {
            return context
        }

        return params["target"]?.objectValue?["context"]?.stringValue
    }

    private func validateContext(_ context: String?) throws {
        guard let context, context != BiDiWebViewHost.contextID else {
            return
        }

        throw BiDiProtocolError.noSuchFrame("Unsupported context: \(context)")
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
