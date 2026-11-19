import Foundation
import PDFKit
import AppKit

/// The shape Claude returns (enforced with structured outputs).
struct AIDocument: Decodable {
    struct Block: Decodable {
        var kind: String
        var text: String?
        var subtitle: String?
        var page: Int?
        var location: String?
        var figure: Figure?
        // The old slider chart, kept so the built-in demo answer and older answers still decode.
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
    struct Figure: Decodable {
        struct Point: Decodable { var x: Double; var y: Double; var label: String }
        struct Series: Decodable { var name: String; var style: String; var points: [Point] }
        var x_label: String
        var y_label: String
        var x_categories: [String]
        var series: [Series]
        var basis: String
        var source: String
    }
    var title: String
    var blocks: [Block]

    /// Blocks with any figure split out into its own figure block. Haiku sometimes attaches the figure
    /// to the heading that introduces it instead of writing a separate block.
    var normalizedBlocks: [Block] {
        blocks.flatMap { b -> [Block] in
            // Haiku often fills in an empty figure on every block; only a figure with points counts.
            var plain = b
            plain.figure = nil
            guard let figure = b.figure, figure.series.contains(where: { !$0.points.isEmpty }) else {
                return b.kind == "figure" ? [] : [plain]
            }
            return b.kind == "figure" ? [b] : [plain, Block(kind: "figure", figure: figure)]
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
    case tooManySteps
    case needsAnalysis

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Claude API key to ask questions."
        case .badKey: "Claude didn't accept that API key. Check it and try again."
        case .http(let code, let message): "Claude returned an error (\(code)): \(message)"
        case .refused: "Claude declined to answer this one."
        case .truncated: "The answer ran too long and was cut off. Try a narrower question."
        case .unreadable: "Claude's answer came back in a shape the app couldn't read. Try again."
        case .tooManySteps: "Claude took too many steps on this one. Try a narrower question."
        case .needsAnalysis: "This question needs analysis."
        }
    }
}

/// What came back from one question: the composed answer, plus the code Claude ran to get there.
struct AgentResult {
    var document: AIDocument
    var code: [String]
}

/// Answers a question with Claude in a short tool loop, like Claude in chat: it can run Python on the
/// paper (code execution, on Anthropic's servers) and look at any page as an image, then composes the
/// answer as structured JSON. Swift has no official Anthropic SDK, so this is raw HTTP.
struct PaperAgent {
    static let maxRequests = 12
    let apiKey: String
    /// A model ID from View ▸ Model. Test override: PAPER_COMPANION_MODEL=claude-sonnet-5-5
    var model: String
    let document: PDFDocument
    let paperText: String
    let paperKey: String

    /// Each response is logged raw for debugging: ~/Library/Application Support/Paper Companion/Logs
    static var logFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paper Companion/Logs", isDirectory: true)
    }

    // MARK: Running a question

    func run(system: [[String: Any]], user: String, step: @escaping @MainActor (String) -> Void) async throws -> AgentResult {
        guard model == AnswerModel.automatic.rawValue else { return try await runWithFiles(system: system, user: user, step: step) }
        // Automatic: Haiku first. The moment it starts running code, start over on Sonnet, which is more
        // careful with multi-step analysis (Haiku misgrouped countries in testing).
        do {
            var haiku = self
            haiku.model = AnswerModel.haiku.rawValue
            haiku.escalateOnCode = true
            return try await haiku.runWithFiles(system: system, user: user, step: step)
        } catch ClaudeError.needsAnalysis {
            await step("Handing this one to Sonnet")
            var sonnet = self
            sonnet.model = AnswerModel.sonnet.rawValue
            return try await sonnet.runWithFiles(system: system, user: user, step: step)
        }
    }

    /// Stop as soon as Claude starts to run code (used by Automatic).
    var escalateOnCode = false

    private func runWithFiles(system: [[String: Any]], user: String, step: @escaping @MainActor (String) -> Void) async throws -> AgentResult {
        do {
            return try await run(system: system, user: user, files: try await paperFiles(), step: step)
        } catch ClaudeError.http(let code, let message) where (code == 400 || code == 404)
                    && message.localizedCaseInsensitiveContains("file") {
            // An uploaded copy of the paper expired or was deleted: upload again, once.
            UserDefaults.standard.removeObject(forKey: filesDefaultsKey)
            return try await run(system: system, user: user, files: try await paperFiles(), step: step)
        }
    }

    private func run(system: [[String: Any]], user: String, files: [String],
                     step: @escaping @MainActor (String) -> Void) async throws -> AgentResult {
        var userContent: [[String: Any]] = [["type": "text", "text": user]]
        userContent += files.map { ["type": "container_upload", "file_id": $0] }
        var messages: [[String: Any]] = [["role": "user", "content": userContent]]
        var container: String?
        var code: [String] = []
        var transcript: [[String: Any]] = []
        let started = Date()

        for _ in 0..<Self.maxRequests {
            var body: [String: Any] = [
                "model": ProcessInfo.processInfo.environment["PAPER_COMPANION_MODEL"] ?? model,
                "max_tokens": 32000,
                "stream": true,
                "output_config": [
                    "effort": "medium",
                    "format": ["type": "json_schema", "schema": "__SCHEMA__"],
                ],
                "tools": Self.tools,
                "system": system,
                "messages": messages,
            ]
            if let container { body["container"] = container }

            let response = try await stream(body: body, step: step)
            transcript.append(["stop_reason": response.stopReason ?? "", "usage": response.usage, "content": response.content])
            container = response.container ?? container
            messages.append(["role": "assistant", "content": response.content])
            code += Self.code(in: response.content)

            switch response.stopReason {
            case "tool_use":
                var results: [[String: Any]] = []
                for block in response.content where block["type"] as? String == "tool_use" {
                    results.append(await toolResult(for: block, step: step))
                }
                messages.append(["role": "user", "content": results])
            case "pause_turn":
                continue   // The server-side loop paused; sending the conversation back resumes it.
            case "refusal":
                log(transcript, seconds: Date().timeIntervalSince(started))
                throw ClaudeError.refused
            case "max_tokens":
                log(transcript, seconds: Date().timeIntervalSince(started))
                throw ClaudeError.truncated
            default:
                log(transcript, seconds: Date().timeIntervalSince(started))
                // The answer is the text after the last tool activity in the final response.
                var text = ""
                for block in response.content {
                    let type = block["type"] as? String ?? ""
                    if type == "text" { text += block["text"] as? String ?? "" }
                    else if type != "thinking" { text = "" }
                }
                guard let doc = try? JSONDecoder().decode(AIDocument.self, from: Data(text.utf8)) else {
                    throw ClaudeError.unreadable
                }
                return AgentResult(document: doc, code: code)
            }
        }
        log(transcript, seconds: Date().timeIntervalSince(started))
        throw ClaudeError.tooManySteps
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        ["type": "code_execution_20260521", "name": "code_execution"],
        [
            "name": "view_page",
            "description": "Look at one page of the paper as an image. Use it to read a figure, chart, diagram, equation or table layout that the extracted text can't show. Pages are numbered as in the paper text (=== Page N ===).",
            "input_schema": [
                "type": "object", "additionalProperties": false,
                "properties": ["page": ["type": "integer", "description": "Page number, as in === Page N ==="]],
                "required": ["page"],
            ],
            "strict": true,
        ],
    ]

    private func toolResult(for block: [String: Any], step: @MainActor (String) -> Void) async -> [String: Any] {
        let id = block["id"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        guard block["name"] as? String == "view_page", let n = input["page"] as? Int else {
            return ["type": "tool_result", "tool_use_id": id, "is_error": true, "content": "Unknown tool."]
        }
        await step("Looking at page \(n)")
        guard let png = Self.pageImage(document, page: n - 1) else {
            return ["type": "tool_result", "tool_use_id": id, "is_error": true,
                    "content": "There is no page \(n). The paper has \(document.pageCount) pages."]
        }
        return ["type": "tool_result", "tool_use_id": id, "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
        ]]
    }

    /// A page rendered about 1500 px tall, white background, as PNG.
    static func pageImage(_ document: PDFDocument, page: Int) -> Data? {
        guard let p = document.page(at: page) else { return nil }
        let box = p.bounds(for: .mediaBox)
        let scale = 1500 / max(box.height, 1)
        let image = p.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The code Claude ran in this response, for the "Show code" view under a computed figure.
    static func code(in content: [[String: Any]]) -> [String] {
        content.compactMap { block in
            guard block["type"] as? String == "server_tool_use", let input = block["input"] as? [String: Any] else { return nil }
            if let text = input["file_text"] as? String { return "# \(input["path"] as? String ?? "script")\n\(text)" }
            if let command = input["command"] as? String, !["view", "create", "str_replace"].contains(command) { return "$ \(command)" }
            if let code = input["code"] as? String { return code }
            return nil
        }
    }

    /// A short, plain description of what Claude is doing, for the progress line.
    static func describe(_ block: [String: Any]) -> String? {
        guard block["type"] as? String == "server_tool_use" else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        let all = ((input["command"] as? String) ?? "") + ((input["file_text"] as? String) ?? "") + ((input["code"] as? String) ?? "")
        if all.contains("pdfplumber") || all.contains("pypdf") { return "Reading the PDF with Python" }
        if all.contains("statsmodels") || all.contains("polyfit") || all.contains("OLS") || all.contains("linregress") {
            return "Running the numbers"
        }
        if let c = input["command"] as? String, ["view", "create", "str_replace"].contains(c) { return "Writing a script" }
        return "Running Python"
    }

    // MARK: The paper, uploaded once into the code container

    private var filesDefaultsKey: String { "files.\(paperKey)" }

    /// File IDs for paper.pdf and paper.txt, uploaded with the Files API the first time they're needed.
    private func paperFiles() async throws -> [String] {
        if let ids = UserDefaults.standard.stringArray(forKey: filesDefaultsKey), ids.count == 2 { return ids }
        guard let pdf = document.dataRepresentation() else { return [] }
        let pdfID = try await upload(pdf, name: "paper.pdf", type: "application/pdf")
        let txtID = try await upload(Data(paperText.utf8), name: "paper.txt", type: "text/plain")
        UserDefaults.standard.set([pdfID, txtID], forKey: filesDefaultsKey)
        return [pdfID, txtID]
    }

    private func upload(_ data: Data, name: String, type: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/files")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let boundary = "pc-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (reply, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ClaudeError.badKey }
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let id = obj["id"] as? String
        else { throw ClaudeError.http(status, Self.errorMessage(reply)) }
        return id
    }

    // MARK: Streaming one request

    private struct Response {
        var content: [[String: Any]] = []
        var stopReason: String?
        var container: String?
        var usage: [String: Any] = [:]
    }

    /// Streams one Messages request and rebuilds its content blocks, reporting steps as they start.
    private func stream(body: [String: Any], step: @escaping @MainActor (String) -> Void) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Sorted keys keep the bytes identical between requests, so the cached paper prefix is reused.
        // The schema is spliced in as fixed text so its property order (the order Claude writes fields in)
        // stays as written: title first, then each block's kind and text before anything else.
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

        var out = Response()
        var partialJSON: [Int: String] = [:]
        var textCount = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "message_start":
                if let m = event["message"] as? [String: Any] {
                    if let u = m["usage"] as? [String: Any] { out.usage.merge(u) { $1 } }
                    if let c = m["container"] as? [String: Any], let id = c["id"] as? String { out.container = id }
                }
            case "content_block_start":
                guard let i = event["index"] as? Int, var block = event["content_block"] as? [String: Any] else { continue }
                if block["type"] as? String == "server_tool_use" || block["type"] as? String == "tool_use" {
                    block["input"] = [String: Any]()
                }
                if escalateOnCode, block["type"] as? String == "server_tool_use" { throw ClaudeError.needsAnalysis }
                while out.content.count <= i { out.content.append([:]) }
                out.content[i] = block
            case "content_block_delta":
                guard let i = event["index"] as? Int, out.content.indices.contains(i),
                      let delta = event["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    out.content[i]["text"] = (out.content[i]["text"] as? String ?? "") + t
                    textCount += t.count
                    if textCount == t.count, !t.isEmpty { await step("Composing the answer") }
                case "thinking_delta":
                    out.content[i]["thinking"] = (out.content[i]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    out.content[i]["signature"] = (out.content[i]["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[i, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
            case "content_block_stop":
                guard let i = event["index"] as? Int, out.content.indices.contains(i) else { continue }
                if let raw = partialJSON[i], !raw.isEmpty,
                   let input = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
                    out.content[i]["input"] = input
                }
                if let label = Self.describe(out.content[i]) { await step(label) }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if let r = delta["stop_reason"] as? String { out.stopReason = r }
                    if let c = delta["container"] as? [String: Any], let id = c["id"] as? String { out.container = id }
                }
                if let u = event["usage"] as? [String: Any] { out.usage.merge(u) { $1 } }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw ClaudeError.http(0, message)
            default:
                break
            }
        }
        return out
    }

    private func log(_ transcript: [[String: Any]], seconds: Double) {
        let entry: [String: Any] = ["model": ProcessInfo.processInfo.environment["PAPER_COMPANION_MODEL"] ?? model, "seconds": (seconds * 10).rounded() / 10, "requests": transcript]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        try? data.write(to: Self.logFolder.appendingPathComponent("last-response.json"))
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return String(data: data, encoding: .utf8) ?? "No details"
    }

    // MARK: Output schema

    /// One flat block shape with a `kind` field, written as ordered JSON text. (An `anyOf` of block shapes
    /// made constrained decoding stick to whichever shape came first, and with `text` last Haiku sometimes
    /// wrote empty blocks.)
    static let schema = #"""
    {"type":"object","additionalProperties":false,"required":["title","blocks"],"properties":{
     "title":{"type":"string","description":"The reader's question as a short heading, in their words."},
     "blocks":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["kind","text","page","location","subtitle"],"properties":{
       "kind":{"type":"string","enum":["prose","quote","heading","figure"]},
       "text":{"type":"string","description":"prose: the paragraph. quote: the exact words from the paper. heading: the title. figure: empty."},
       "page":{"type":"integer","description":"quote: the page number as marked in the paper text. Other kinds: 0."},
       "location":{"type":"string","description":"quote: where it sits, such as a section name or \"Figure 1 caption\". Other kinds: empty."},
       "subtitle":{"type":"string","description":"heading: one line saying what the figure below shows. Other kinds: empty."},
       "figure":{"type":"object","additionalProperties":false,
        "description":"Only on a figure block, its own block right after the heading that introduces it. Leave out on every other kind.",
        "required":["x_label","y_label","x_categories","series","basis","source"],"properties":{
         "x_label":{"type":"string"},
         "y_label":{"type":"string"},
         "x_categories":{"type":"array","items":{"type":"string"},"description":"Names for a categorical x axis, where each point's x is an index into this list. Empty when x is numeric."},
         "series":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","style","points"],"properties":{
          "name":{"type":"string","description":"A short legend label, a few words."},
          "style":{"type":"string","enum":["points","line","dashed","bars"],"description":"points: a scatter. line or dashed: points joined in x order (a fitted line needs only its two end points). bars: a bar per point."},
          "points":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["x","y","label"],"properties":{
           "x":{"type":"number"},"y":{"type":"number"},
           "label":{"type":"string","description":"Short label drawn by the point, such as a country code. Empty for none."}}}}}}},
         "basis":{"type":"string","enum":["paper","computed","read_off_figure"],"description":"paper: every number is printed in the paper. computed: you calculated some of it with code. read_off_figure: values estimated from a figure image."},
         "source":{"type":"string","description":"Where the data comes from, in a few words, such as \"Appendix Table A2\" or \"Figure 3\". Details belong in the prose."}}}}}}}}
    """#
}
