import Foundation

@MainActor
struct BiDiParameterDecoder {
    func requiredParams(_ params: [String: JSONValue]?) throws -> [String: JSONValue] {
        guard let params else {
            throw BiDiProtocolError.invalidArgument("params is required")
        }

        return params
    }

    func requiredStringArray(_ value: JSONValue?, name: String) throws -> [String] {
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

    func requiredObject(_ value: JSONValue?, name: String) throws -> [String: JSONValue] {
        guard let object = value?.objectValue else {
            throw BiDiProtocolError.invalidArgument("\(name) must be an object")
        }

        return object
    }

    func requiredPositiveInt(_ value: JSONValue?, name: String) throws -> Int {
        guard let intValue = value?.intValue, intValue > 0 else {
            throw BiDiProtocolError.invalidArgument("\(name) must be a positive integer")
        }

        return intValue
    }

    func requiredString(_ value: JSONValue?, name: String) throws -> String {
        guard let string = value?.stringValue, !string.isEmpty else {
            throw BiDiProtocolError.invalidArgument("\(name) is required")
        }

        return string
    }

    func optionalContextSet(_ value: JSONValue?) throws -> Set<String>? {
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

    func validateOptionalContextList(_ value: JSONValue?) throws {
        _ = try optionalContextSet(value)
    }

    func optionalContext(from params: [String: JSONValue]?) -> String? {
        guard let params else {
            return nil
        }

        if let context = params["context"]?.stringValue {
            return context
        }

        return params["target"]?.objectValue?["context"]?.stringValue
    }

    func validateContext(_ context: String?) throws {
        guard let context, context != BiDiWebViewHost.contextID else {
            return
        }

        throw BiDiProtocolError.noSuchFrame("Unsupported context: \(context)")
    }

    func validateTarget(_ target: JSONValue?) throws {
        guard let target else {
            return
        }

        guard let object = target.objectValue else {
            throw BiDiProtocolError.invalidArgument("target must be an object")
        }

        try validateContext(object["context"]?.stringValue)
    }

    func navigationWait(from value: JSONValue?) throws -> BiDiNavigationWait {
        guard let value else {
            return .complete
        }

        guard let rawValue = value.stringValue, let wait = BiDiNavigationWait(rawValue: rawValue) else {
            throw BiDiProtocolError.invalidArgument("wait must be one of none, interactive, complete")
        }

        return wait
    }

    func scrapeWaitOptions(from params: [String: JSONValue]) throws -> (timeout: TimeInterval, pollInterval: TimeInterval) {
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

    func optionalMilliseconds(_ value: JSONValue?, name: String, defaultValue: TimeInterval) throws -> TimeInterval {
        guard let value else {
            return defaultValue
        }

        guard let milliseconds = value.doubleValue, milliseconds > 0 else {
            throw BiDiProtocolError.invalidArgument("\(name) must be a positive number of milliseconds")
        }

        return milliseconds / 1000
    }

    func scrapeExtractOptions(from params: [String: JSONValue]) throws -> BiDiScrapeExtractOptions {
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

    func cookieDefinition(from params: [String: JSONValue], currentURL: URL?) throws -> CookieDefinition {
        let object = params["cookie"]?.objectValue ?? params
        let name = try requiredString(object["name"], name: "cookie.name")
        let value = try cookieValueString(object["value"])
        let domain = try cookieDomain(from: object, currentURL: currentURL)
        let path = object["path"]?.stringValue ?? "/"
        let secure = object["secure"]?.boolValue ?? (currentURL?.scheme == "https")
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

    func cookieFilter(from params: [String: JSONValue]) throws -> BiDiCookieFilter {
        let object = params["filter"]?.objectValue ?? params
        return BiDiCookieFilter(
            name: object["name"]?.stringValue,
            domain: object["domain"]?.stringValue,
            path: object["path"]?.stringValue
        )
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

    private func cookieDomain(from object: [String: JSONValue], currentURL: URL?) throws -> String {
        if let domain = object["domain"]?.stringValue, !domain.isEmpty {
            return domain
        }

        if let host = currentURL?.host, !host.isEmpty {
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
}
