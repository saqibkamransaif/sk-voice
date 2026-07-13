import Foundation

/// NDJSON messages exchanged with the Node sidecar (see sidecar/src/protocol.ts).
public enum SidecarRequest: Equatable, Sendable {
    case ping(id: String)
    case refine(id: String, transcript: String, context: String, appName: String)

    public var id: String {
        switch self {
        case .ping(let id): id
        case .refine(let id, _, _, _): id
        }
    }

    /// One NDJSON line, newline-terminated.
    public func encoded() throws -> Data {
        var object: [String: String]
        switch self {
        case .ping(let id):
            object = ["id": id, "type": "ping"]
        case .refine(let id, let transcript, let context, let appName):
            object = ["id": id, "type": "refine", "transcript": transcript,
                      "context": context, "appName": appName]
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }
}

public enum SidecarResponse: Equatable, Sendable {
    case pong(id: String)
    case result(id: String, text: String)
    case error(id: String, message: String)

    public var id: String {
        switch self {
        case .pong(let id): id
        case .result(let id, _): id
        case .error(let id, _): id
        }
    }

    /// Parses one NDJSON line.
    public static func decode(line: Data) -> SidecarResponse? {
        guard let raw = try? JSONSerialization.jsonObject(with: line),
              let object = raw as? [String: Any],
              let id = object["id"] as? String,
              let type = object["type"] as? String else { return nil }
        switch type {
        case "pong":
            return .pong(id: id)
        case "result":
            guard let text = object["text"] as? String else { return nil }
            return .result(id: id, text: text)
        case "error":
            return .error(id: id, message: object["message"] as? String ?? "unknown")
        default:
            return nil
        }
    }
}
