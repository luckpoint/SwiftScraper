import Foundation

@MainActor
final class BiDiDispatcher {
    private let host: BiDiWebViewHost

    init(host: BiDiWebViewHost) {
        self.host = host
    }

    func handle(_ request: BiDiRequest) async -> BiDiResponse {
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

            case "session.end", "session.subscribe", "session.unsubscribe":
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

                let navigationID = try await host.load(url: url)
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

                let navigationID = try await host.load(url: url)
                return .success(
                    id: id,
                    result: [
                        "navigation": .string(navigationID),
                        "url": .string(url.absoluteString),
                    ]
                )

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

            case "scrape.getHTML":
                try validateContext(optionalContext(from: request.params))
                let html = try await host.getHTML()
                return valueResponse(id: id, value: .string(html))

            case "scrape.getText":
                try validateContext(optionalContext(from: request.params))
                let text = try await host.getText()
                return valueResponse(id: id, value: .string(text))

            default:
                throw BiDiProtocolError.unknownCommand("Unsupported method: \(request.method)")
            }
        } catch let error as BiDiProtocolError {
            return .failure(id: id, error: error.code, message: error.message)
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

    private func requiredParams(_ params: [String: JSONValue]?) throws -> [String: JSONValue] {
        guard let params else {
            throw BiDiProtocolError.invalidArgument("params is required")
        }

        return params
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
