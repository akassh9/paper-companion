import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Test flag: `--appearance dark|light` previews the app in a mode other than the Mac's own.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), args.indices.contains(i + 1) {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct Launcher {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), args.indices.contains(i + 1) {
            exit(SelfTest.run(path: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--ask") {
            let rest = Array(args[(i + 1)...])
            Task { exit(await AskTest.run(args: rest)) }
            RunLoop.main.run()
        }
        PaperCompanionApp.main()
    }
}

struct PaperCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Paper Companion") {
            SpaceView(model: model)
                .frame(minWidth: 1180, minHeight: 760)
                .onAppear {
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) {
                        model.open(url: URL(fileURLWithPath: args[i + 1]))
                        if args.contains("--demo") || args.contains("--demo-persist") {
                            DemoAnswer.run(model: model, persist: args.contains("--demo-persist"))
                        }
                        if let j = args.firstIndex(of: "--select"), args.indices.contains(j + 1) {
                            let text = args[j + 1]
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.pdf.select(text: text) }
                        }
                        // Test flag: `--answer-html file.html` shows a saved answer page, without calling Claude.
                        if let j = args.firstIndex(of: "--answer-html"), args.indices.contains(j + 1),
                           let html = try? String(contentsOfFile: args[j + 1], encoding: .utf8) {
                            model.persistenceEnabled = false
                            model.threads = []
                            model.openThreadID = nil
                            model.finishHTML(html, code: ["# (test) code would appear here"], mode: .compose,
                                             question: "Test", passages: [], threadID: nil)
                        }
                        // Test flag: `--claims` opens the claims map (`--claims new` maps again).
                        if let j = args.firstIndex(of: "--claims") {
                            let again = args.indices.contains(j + 1) && args[j + 1] == "new"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { model.mapClaims(force: again) }
                        }
                        // Test flag: `--links` opens Links mode. `--link "a" "b"` then joins two passages as if
                        // drawn (without saving), and `--link-confirm` accepts Claude's suggestion.
                        if args.contains("--links") || args.contains("--link") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.openLinks() }
                        }
                        if let j = args.firstIndex(of: "--link"), args.indices.contains(j + 2) {
                            model.persistenceEnabled = false
                            let (a, b) = (args[j + 1], args[j + 2])
                            let confirm = args.contains("--link-confirm")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                Self.drawTestLink(model: model, a: a, b: b, confirm: confirm)
                            }
                        }
                        // Test flag: `--whatif "text in the paper" "new value"` changes it, as if typed.
                        if let j = args.firstIndex(of: "--whatif"), args.indices.contains(j + 2) {
                            let (text, value) = (args[j + 1], args[j + 2])
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.openWhatIf() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                model.pdf.select(text: text)
                                if let span = model.selection?.span { model.pdf.show(span) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    model.whatIfEditing?.value = value
                                    print("whatif test: editing \(model.whatIfEditing?.original ?? "nothing")")
                                    model.estimateWhatIf()
                                    // `--whatif-keep` then keeps the result as an answer thread (without saving).
                                    if args.contains("--whatif-keep") {
                                        model.persistenceEnabled = false
                                        func wait() {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                if model.whatIf?.result != nil { model.keepWhatIfAsBranch() }
                                                else if model.whatIf?.isEstimating == true { wait() }
                                            }
                                        }
                                        wait()
                                    }
                                }
                            }
                        }
                        // Test flag: `--page N` opens the paper at page N.
                        if let j = args.firstIndex(of: "--page"), args.indices.contains(j + 1), let n = Int(args[j + 1]) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if let page = model.document?.page(at: n - 1) { model.pdf.go(to: page) }
                            }
                        }
                        // Test flag: `--question "…"` asks it as a new thread (with any --select), without saving.
                        if let j = args.firstIndex(of: "--question"), args.indices.contains(j + 1) {
                            let q = args[j + 1]
                            model.persistenceEnabled = false
                            model.threads = []
                            model.openThreadID = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                model.mode = .compose
                                model.question = q
                                model.send()
                            }
                            // Test flag: `--branch "passage" "question"` then selects another passage and
                            // branches the answer with it, the way a reader would with the Branch button.
                            if let k = args.firstIndex(of: "--branch"), args.indices.contains(k + 2) {
                                Self.branchWhenReady(model: model, passage: args[k + 1], question: args[k + 2])
                            }
                        }
                    } else if model.document == nil {
                        model.reopenLast()
                    }
                }
                .onOpenURL { url in model.open(url: url) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1560, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Open Sample Paper") { model.openSample() }
            }
            CommandGroup(after: .toolbar) {
                Button(model.showingClaims ? "Close Claims Map" : "Map Claims") {
                    model.showingClaims ? model.closeClaims() : model.mapClaims()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.document == nil)
                Button(model.showingLinks ? "Leave Links" : "Draw Links") {
                    model.showingLinks ? model.closeLinks() : model.openLinks()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.document == nil)
                Button(model.showingWhatIf ? "Leave What-if" : "What If…") {
                    model.showingWhatIf ? model.closeWhatIf() : model.openWhatIf()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.document == nil)
                Divider()
                Picker("Model", selection: Binding(get: { model.answerModel }, set: { model.answerModel = $0 })) {
                    ForEach(AnswerModel.allCases) { Text($0.label).tag($0) }
                }
                Picker("Backdrop", selection: Binding(get: { model.backdrop }, set: { model.backdrop = $0 })) {
                    ForEach(Backdrop.allCases) { Text($0.label).tag($0) }
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Claude API Key…") { model.showKeySheet = true }
            }
        }
    }
}

extension PaperCompanionApp {
    /// Waits for the first answer to land, then selects `passage` and branches the answer with `question`.
    @MainActor static func branchWhenReady(model: AppModel, passage: String, question: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard model.openThread != nil, !model.isComposing else {
                return branchWhenReady(model: model, passage: passage, question: question)
            }
            model.pdf.select(text: passage)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("branch test: selection \(model.selection == nil ? "missing" : "set"), mode before \(model.mode)")
                model.mode = .branch
                model.question = question
                model.send()
            }
        }
    }

    /// Joins two passages as if the reader drew a line between them (test flag `--link`).
    @MainActor static func drawTestLink(model: AppModel, a: String, b: String, confirm: Bool) {
        guard let index = model.index, let doc = model.document,
              let sa = index.locate(a, preferredPage: nil), let sb = index.locate(b, preferredPage: nil) else {
            print("link test: couldn't find a passage"); return
        }
        model.links = []
        if let page = doc.page(at: sa.page) { model.pdf.go(to: page) }
        model.linkDraft = LinkDraft(a: PaperLink.End(span: sa, text: index.text(of: sa, in: doc)),
                                    b: PaperLink.End(span: sb, text: index.text(of: sb, in: doc)))
        model.suggestRelation()
        guard confirm else { return }
        func wait() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let s = model.linkDraft?.suggestion { model.confirmLink(s.relation) }
                else if model.linkDraft != nil { wait() }
            }
        }
        wait()
    }
}
