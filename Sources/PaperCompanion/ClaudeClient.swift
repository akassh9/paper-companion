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
        /// Claude puts chart data here; the flat fields above are kept for the built-in demo answer.
        var chart: Chart?
    }
    struct Chart: Decodable {
        var x_label: String
        var x_values: [String]
        var series: [Series]
        var start_index: Int
    }
    struct Series: Decodable {
        var name: String
        var unit: String
        var values: [Double]
    }
    var title: String
    var blocks: [Block]

    /// Blocks with any chart data split out into its own instrument block. Haiku sometimes attaches the chart
    /// to the heading that introduces it instead of writing a separate instrument block.
    var normalizedBlocks: [Block] {
        blocks.flatMap { b -> [Block] in
            guard b.kind != "instrument", let chart = b.chart else { return [b] }
            var plain = b
            plain.chart = nil
            let inst = Block(kind: "instrument", chart: chart)
            return [plain, inst]
        }
    }
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
    static let model = "claude-haiku-5-5"
    let apiKey: String

    /// The last response, raw, for debugging: ~/Library/Application Support/Paper Companion/Logs/last-response.json
    static var logFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paper Companion/Logs", isDirectory: true)
    }

    /// Streams the response and returns the parsed document. `progress` gets the running count of characters.
    /// Claude Haiku 5.5 has no server-side refusal fallback, so a refusal surfaces as `.refused`.
    func compose(system: [[String: Any]], user: String, progress: @escaping @MainActor (Int) -> Void) async throws -> AIDocument {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "stream": true,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": "__SCHEMA__"],
            ],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        // Sorted keys keep the bytes identical between requests, so the cached paper prefix is reused.
        // The schema is spliced in as fixed text so its property order (which is the order Claude writes
        // fields in) stays as written: title first, then each block's kind and text before anything else.
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        request.httpBody = Data(json.replacingOccurrences(of: "\"__SCHEMA__\"", with: Self.schema).utf8)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            if status == 401 { throw ClaudeError.badKey }
            throw ClaudeError.http(status, Self.errorMessage(data))
        }

        // Server-sent events. Only text deltas make up the answer (thinking blocks are skipped).
        var text = ""
        var stopReason: String?
        var usage: [String: Any] = [:]
        let started = Date()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "message_start":
                if let m = event["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                    usage.merge(u) { $1 }
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
                if let u = event["usage"] as? [String: Any] { usage.merge(u) { $1 } }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw ClaudeError.http(0, message)
            default:
                break
            }
        }

        Self.log(user: user, text: text, stopReason: stopReason, usage: usage, seconds: Date().timeIntervalSince(started))
        if stopReason == "refusal" { throw ClaudeError.refused }
        if stopReason == "max_tokens" { throw ClaudeError.truncated }
        guard let data = text.data(using: .utf8),
              let doc = try? JSONDecoder().decode(AIDocument.self, from: data)
        else { throw ClaudeError.unreadable }
        return doc
    }

    private static func log(user: String, text: String, stopReason: String?, usage: [String: Any], seconds: Double) {
        let entry: [String: Any] = [
            "model": model, "seconds": (seconds * 10).rounded() / 10, "stop_reason": stopReason ?? "",
            "usage": usage, "user_message": user,
            "response": (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        try? data.write(to: logFolder.appendingPathComponent("last-response.json"))
    }

    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return String(data: data, encoding: .utf8) ?? "No details"
    }

    // MARK: Output schema

    /// One flat block shape with a `kind` field, written as ordered JSON text. (An `anyOf` of four block shapes
    /// made constrained decoding stick to whichever shape came first: answers came back all prose or all quotes.
    /// And with `text` last, Haiku sometimes wrote empty blocks.)
    static let schema = #"""
    {"type":"object","additionalProperties":false,"required":["title","blocks"],"properties":{
     "title":{"type":"string","description":"The reader's question as a short heading, in their words."},
     "blocks":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["kind","text","page","location","subtitle"],"properties":{
       "kind":{"type":"string","enum":["prose","quote","heading","instrument"]},
       "text":{"type":"string","description":"prose: the paragraph. quote: the exact words from the paper. heading: the title. instrument: empty."},
       "page":{"type":"integer","description":"quote: the page number as marked in the paper text. Other kinds: 0."},
       "location":{"type":"string","description":"quote: where it sits, such as a section name or \"Figure 1 caption\". Other kinds: empty."},
       "subtitle":{"type":"string","description":"heading: one line saying what the chart below shows. Other kinds: empty."},
       "chart":{"type":"object","additionalProperties":false,"description":"Only on an instrument block, its own block right after the heading that introduces it. Leave out on every other kind.",
        "required":["x_label","x_values","series","start_index"],"properties":{
         "x_label":{"type":"string"},
         "x_values":{"type":"array","items":{"type":"string"}},
         "series":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","unit","values"],
          "properties":{"name":{"type":"string"},"unit":{"type":"string"},"values":{"type":"array","items":{"type":"number"}}}}},
         "start_index":{"type":"integer"}}}}}}}}
    """#
}
