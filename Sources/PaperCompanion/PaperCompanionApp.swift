import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
            CommandGroup(after: .appSettings) {
                Button("Claude API Key…") { model.showKeySheet = true }
            }
        }
    }
}
