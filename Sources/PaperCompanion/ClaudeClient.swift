import Foundation

/// The shape Claude returns (enforced with structured outputs).
struct AIDocument: Decodable {
    struct Block: Decodable {
        var kind: String
        var text: String?
        var subtitle: String?
        var page: Int?
        var location: String?
        var x_label: String?
        var x_values: [String]?
        var series: [Series]?
        var start_index: Int?
    }
    struct Series: Decodable {
        var name: String
        var unit: String
        var values: [Double]
    }
    var title: String
    var blocks: [Block]
}

enum ClaudeError: LocalizedError {
    case missingKey
    case badKey
    case http(Int, String)
    case refused
    case truncated
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Claude API key to ask questions."
        case .badKey: "Claude didn't accept that API key. Check it and try again."
        case .http(let code, let message): "Claude returned an error (\(code)): \(message)"
        case .refused: "Claude declined to answer this one."
        case .truncated: "The answer ran too long and was cut off. Try a narrower question."
        case .unreadable: "Claude's answer came back in a shape the app couldn't read. Try again."
        }
    }
}

/// Calls the Claude Messages API over HTTPS. Swift has no official Anthropic SDK, so this is raw HTTP.
struct ClaudeClient {
    static let model = "claude-opus-5-5"
    let apiKey: String

    /// Streams the response and returns the parsed document. `progress` gets the running count of characters.
    func compose(system: [[String: Any]], user: String, progress: @escaping @MainActor (Int) -> Void) async throws -> AIDocument {
        do {
            return try await compose(system: system, user: user, useFallbacks: true, progress: progress)
        } catch ClaudeError.http(400, let message) where message.localizedCaseInsensitiveContains("fallback") {
            // Older API surfaces may not accept server-side fallbacks; retry once without them.
            return try await compose(system: system, user: user, useFallbacks: false, progress: progress)
        }
    }

    private func compose(system: [[String: Any]], user: String, useFallbacks: Bool,
                         progress: @escaping @MainActor (Int) -> Void) async throws -> AIDocument {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Server-side fallback: if a safety classifier declines, the API retries on a fallback model.
        if useFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "stream": true,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        if useFallbacks { body["fallbacks"] = "default" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            if status == 401 { throw ClaudeError.badKey }
            throw ClaudeError.http(status, Self.errorMessage(data))
        }

        // Server-sent events. Keep only text from the last model that ran (a fallback restarts the answer).
        var text = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "fallback" {
                    text = ""
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                    let count = text.count
                    await progress(count)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let r = delta["stop_reason"] as? String { stopReason = r }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw ClaudeError.http(0, message)
            default:
                break
            }
        }

        if stopReason == "refusal" { throw ClaudeError.refused }
        if stopReason == "max_tokens" { throw ClaudeError.truncated }
        guard let data = text.data(using: .utf8),
              let doc = try? JSONDecoder().decode(AIDocument.self, from: data)
        else { throw ClaudeError.unreadable }
        return doc
    }

    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return String(data: data, encoding: .utf8) ?? "No details"
    }

    // MARK: Output schema

    static let schema: [String: Any] = {
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "properties": props, "required": Array(props.keys).sorted()]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let prose = obj(["kind": ["type": "string", "enum": ["prose"]], "text": str])
        let heading = obj(["kind": ["type": "string", "enum": ["heading"]], "text": str, "subtitle": str])
        let quote = obj(["kind": ["type": "string", "enum": ["quote"]], "text": str, "page": int, "location": str])
        let series = obj(["name": str, "unit": str, "values": ["type": "array", "items": ["type": "number"]]])
        let instrument = obj([
            "kind": ["type": "string", "enum": ["instrument"]],
            "x_label": str,
            "x_values": ["type": "array", "items": str],
            "series": ["type": "array", "items": series],
            "start_index": int,
        ])
        return obj([
            "title": str,
            "blocks": ["type": "array", "items": ["anyOf": [prose, heading, quote, instrument]]],
        ])
    }()
}
