import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }

        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }

        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.rounded() == value:
            return Int(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value):
            return Double(value)
        case .double(let value):
            return value
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }

        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }

        return nil
    }

    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let value):
            return value.map(\.foundationValue)
        case .object(let value):
            return value.mapValues(\.foundationValue)
        }
    }

    init(webKitValue value: Any?) {
        guard let value, !(value is NSNull) else {
            self = .null
            return
        }

        switch value {
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as Float:
            self = .double(Double(value))
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = .double(value.doubleValue)
        case let value as [Any]:
            self = .array(value.map { JSONValue(webKitValue: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { JSONValue(webKitValue: $0) })
        case let value as NSDictionary:
            var object: [String: JSONValue] = [:]
            for (key, rawValue) in value {
                if let key = key as? String {
                    object[key] = JSONValue(webKitValue: rawValue)
                }
            }
            self = .object(object)
        case let value as NSArray:
            self = .array(value.map { JSONValue(webKitValue: $0) })
        default:
            self = .string(String(describing: value))
        }
    }

    func remoteValue() -> JSONValue {
        switch self {
        case .null:
            return .object(["type": .string("null")])
        case .bool(let value):
            return .object(["type": .string("boolean"), "value": .bool(value)])
        case .int(let value):
            return .object(["type": .string("number"), "value": .int(value)])
        case .double(let value):
            return .object(["type": .string("number"), "value": .double(value)])
        case .string(let value):
            return .object(["type": .string("string"), "value": .string(value)])
        case .array(let values):
            return .object([
                "type": .string("array"),
                "value": .array(values.map { $0.remoteValue() }),
            ])
        case .object(let value):
            return .object([
                "type": .string("object"),
                "value": .array(
                    value.keys.sorted().map { key in
                        .array([
                            .string(key),
                            value[key]?.remoteValue() ?? .null,
                        ])
                    }
                ),
            ])
        }
    }
}

struct BiDiRequest: Decodable, Sendable {
    let id: Int?
    let method: String
    let params: [String: JSONValue]?
}

struct BiDiResponse: Encodable, Sendable {
    let id: Int
    let type: String
    let result: [String: JSONValue]?
    let error: String?
    let message: String?
    let stacktrace: String?

    static func success(id: Int, result: [String: JSONValue] = [:]) -> BiDiResponse {
        BiDiResponse(id: id, type: "success", result: result, error: nil, message: nil, stacktrace: nil)
    }

    static func failure(id: Int, error: String, message: String, stacktrace: String? = nil) -> BiDiResponse {
        BiDiResponse(id: id, type: "error", result: nil, error: error, message: message, stacktrace: stacktrace)
    }
}

struct BiDiEvent: Encodable, Sendable {
    let type = "event"
    let method: String
    let params: [String: JSONValue]

    var contextID: String? {
        if let context = params["context"]?.stringValue {
            return context
        }

        return params["source"]?.objectValue?["context"]?.stringValue
    }
}

enum BiDiProtocolError: Error, Equatable {
    case invalidArgument(String)
    case noSuchFrame(String)
    case unknownCommand(String)
    case javascriptError(message: String, stacktrace: String?)

    var code: String {
        switch self {
        case .invalidArgument:
            return "invalid argument"
        case .noSuchFrame:
            return "no such frame"
        case .unknownCommand:
            return "unknown command"
        case .javascriptError:
            return "javascript error"
        }
    }

    var message: String {
        switch self {
        case .invalidArgument(let message), .noSuchFrame(let message), .unknownCommand(let message):
            return message
        case .javascriptError(let message, _):
            return message
        }
    }

    var stacktrace: String? {
        switch self {
        case .javascriptError(_, let stacktrace):
            return stacktrace
        case .invalidArgument, .noSuchFrame, .unknownCommand:
            return nil
        }
    }
}

enum BiDiNavigationWait: String, Sendable {
    case none
    case interactive
    case complete
}

struct BiDiScrapeWaitResult: Sendable {
    let matched: Bool
    let elapsedMilliseconds: Int
    let attempts: Int
}

struct BiDiScrapeAutoScrollResult: Sendable {
    let scrollTop: Double
    let scrollHeight: Double
    let clientHeight: Double
    let reachedBottom: Bool
    let steps: Int
    let elapsedMilliseconds: Int
}

struct BiDiScrapeExtractOptions: Sendable {
    let extraction: ExtractionMode
    let outputFormat: OutputFormat
    let prettyPrint: Bool
    let imageExtraction: ImageExtractionConfiguration
}

struct BiDiScrapeExtractResult: Sendable {
    let data: String
    let imageCandidateCount: Int?
    let imageKeptCount: Int?
    let imageDebugJSON: String?
}

final class BiDiClientSession: @unchecked Sendable {
    private enum ContextFilter: Sendable, Equatable {
        case all
        case only(Set<String>)
    }

    private let lock = NSLock()
    private var subscriptions: [String: ContextFilter] = [:]

    func subscribe(events: [String], contexts: Set<String>?) {
        lock.lock()
        defer { lock.unlock() }

        for event in events {
            guard !event.isEmpty else {
                continue
            }

            if contexts == nil {
                subscriptions[event] = .all
            } else if case .only(var existingContexts) = subscriptions[event] {
                existingContexts.formUnion(contexts ?? [])
                subscriptions[event] = .only(existingContexts)
            } else if subscriptions[event] == nil {
                subscriptions[event] = .only(contexts ?? [])
            }
        }
    }

    func unsubscribe(events: [String], contexts: Set<String>?) {
        lock.lock()
        defer { lock.unlock() }

        for event in events {
            guard !event.isEmpty else {
                continue
            }

            guard let contexts else {
                subscriptions.removeValue(forKey: event)
                continue
            }

            guard let existingFilter = subscriptions[event] else {
                subscriptions.removeValue(forKey: event)
                continue
            }

            guard case .only(let existingContexts) = existingFilter else {
                subscriptions.removeValue(forKey: event)
                continue
            }

            let remainingContexts = existingContexts.subtracting(contexts)
            if remainingContexts.isEmpty {
                subscriptions.removeValue(forKey: event)
            } else {
                subscriptions[event] = .only(remainingContexts)
            }
        }
    }

    func isSubscribed(to event: BiDiEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        for key in Self.subscriptionKeys(for: event.method) {
            guard let filter = subscriptions[key] else {
                continue
            }

            switch filter {
            case .all:
                return true
            case .only(let contexts):
                if let contextID = event.contextID, contexts.contains(contextID) {
                    return true
                }
            }
        }

        return false
    }

    private static func subscriptionKeys(for method: String) -> [String] {
        guard let dotIndex = method.firstIndex(of: ".") else {
            return [method]
        }

        return [method, String(method[..<dotIndex])]
    }
}
