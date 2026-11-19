import Foundation
import PDFKit

/// `PaperCompanion --selftest <pdf>`: checks that known sentences are found in the PDF text.
enum SelfTest {
    static func run(path: String) -> Int32 {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { print("can't open"); return 1 }
        let index = PaperIndex(document: doc, fallbackTitle: "test")
        print("Title:", index.title, "| Body font:", index.bodyFontName, "| Pages:", index.pages.count)
        let quotes: [(String, Int?)] = [
            ("Dense attention improves up to 4K tokens and then degrades, which we attribute to attention entropy rising as the number of candidate positions grows.", 3),
            ("Dense attention exhausts memory beyond 32K tokens on a single 80 GB accelerator, while SRA continues to improve.", 1),
            ("SRA matches dense attention at 4K tokens and outperforms it beyond 16K", 1),
            ("Local and sliding-window attention [2], [3] restricts each token to a fixed neighborhood, which is efficient but blind to distant evidence.", nil),
            ("At 32K tokens SRA requires 9.7 GB, compared with 61 GB for dense attention.", 3),
            ("The loss weight is set to 0.01 and is annealed to 0.001 over the first 10K steps.", 2),
        ]
        var failures = 0
        for (q, page) in quotes {
            if let span = index.locate(q, preferredPage: page.map { $0 - 1 }) {
                let found = index.text(of: span, in: doc)
                print("OK   p\(span.page + 1) [\(span.location)+\(span.length)] \(found.prefix(70))…")
            } else {
                failures += 1
                print("MISS \(q.prefix(70))")
            }
        }
        print(String(index.promptText.prefix(600)))
        return failures == 0 ? 0 : 2
    }
}

/// `PaperCompanion --open <pdf> --demo`: runs a canned answer through the real pipeline (quote matching,
/// colors, highlights, beams) without calling Claude, for checking layout. Nothing is saved.
enum DemoAnswer {
    static let json = """
    {"title":"Why does dense attention fall apart past 4K?","blocks":[
     {"kind":"prose","text":"Two separate failures stack up. The first is that attention spreads thin as the context grows:"},
     {"kind":"quote","text":"Dense attention improves up to 4K tokens and then degrades, which we attribute to attention entropy rising as the number of candidate positions grows.","page":3,"location":"Scaling With Context Length"},
     {"kind":"heading","text":"What it costs to look everywhere","subtitle":"Peak memory from Fig. 3, built for this question"},
     {"kind":"instrument","x_label":"Context length","x_values":["4K","8K","16K","32K"],"series":[{"name":"Dense","unit":"GB","values":[4.1,9.3,23.8,61]},{"name":"SRA","unit":"GB","values":[1.6,2.9,5.2,9.7]}],"start_index":3},
     {"kind":"prose","text":"The second is simpler. Past 32K, it no longer fits:"},
     {"kind":"quote","text":"Dense attention exhausts memory beyond 32K tokens on a single 80 GB accelerator, while SRA continues to improve.","page":1,"location":"Figure 1 caption"},
     {"kind":"prose","text":"SRA avoids both, which is what lets the authors claim:"},
     {"kind":"quote","text":"SRA matches dense attention at 4K tokens and outperforms it beyond 16K","page":1,"location":"Abstract"}
    ]}
    """

    @MainActor
    static func run(model: AppModel, persist: Bool = false) {
        model.persistenceEnabled = persist
        model.threads = []
        model.openThreadID = nil
        guard let index = model.index, let doc = model.document,
              let span = index.locate("Local and sliding-window attention [2], [3] restricts each token to a fixed neighborhood, which is efficient but blind to distant evidence.", preferredPage: 0),
              let ai = try? JSONDecoder().decode(AIDocument.self, from: Data(json.utf8))
        else { return }
        let passage = Passage(span: span, text: index.text(of: span, in: doc), colorIndex: 3)
        model.finish(doc: ai, mode: .compose, question: ai.title, passages: [passage], threadID: nil)
        // Test flag: `--hover-quote N` emphasizes the Nth quote's beam, as if the pointer were over it.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hover-quote"), args.indices.contains(i + 1), let n = Int(args[i + 1]),
           let quotes = model.openThread?.current?.quoteBlocks, quotes.indices.contains(n - 1) {
            model.geometry.hoveredSource = model.sourceID(for: quotes[n - 1])
        }
    }
}

/// `PaperCompanion --ask <pdf> <question> [selected text]`: sends one real question through the same prompt and
/// client the app uses, then prints the blocks and whether each quote was found. Uses the Keychain key.
enum AskTest {
    static func run(args: [String]) async -> Int32 {
        guard args.count >= 2, let doc = PDFDocument(url: URL(fileURLWithPath: args[0])) else { print("usage: --ask <pdf> <question> [selection]"); return 1 }
        guard let key = APIKeyStore.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else { print("no key"); return 1 }
        let index = PaperIndex(document: doc, fallbackTitle: "paper")
        var passages: [Passage] = []
        if args.count >= 3 {
            guard let span = index.locate(args[2], preferredPage: nil) else { print("selection not found"); return 1 }
            passages = [Passage(span: span, text: index.text(of: span, in: doc), colorIndex: 0)]
        }
        let system = Prompts.system(paperTitle: index.title, paperText: index.promptText)
        let user = Prompts.user(mode: .compose, question: args[1], passages: passages, thread: nil)
        do {
            let ai = try await ClaudeClient(apiKey: key).compose(system: system, user: user) { _ in }
            print("TITLE:", ai.title)
            for b in ai.normalizedBlocks {
                switch b.kind {
                case "quote":
                    let found = index.locate(b.text ?? "", preferredPage: b.page.map { $0 - 1 }) != nil
                    print("QUOTE [\(found ? "found" : "MISSING")] p\(b.page ?? 0) \(b.location ?? ""): \(b.text ?? "")")
                case "instrument":
                    let c = b.chart
                    print("CHART:", c?.x_label ?? "", c?.x_values ?? [], c?.series.map { "\($0.name)=\($0.values)" } ?? [])
                default:
                    print(b.kind.uppercased() + ":", b.text ?? "", b.subtitle ?? "")
                }
            }
            return 0
        } catch {
            print("ERROR:", error.localizedDescription)
            return 1
        }
    }
}
