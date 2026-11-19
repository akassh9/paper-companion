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
