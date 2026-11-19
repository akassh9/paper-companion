import SwiftUI

/// The glass question bar: what you're asking about, your question, and how the answer should change.
struct QuestionBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.errorMessage, model.openThread != nil {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
            }
            HStack(spacing: 10) {
                scopeToken

                TextField(placeholder, text: $model.question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { model.send() }
                    .disabled(model.isComposing)

                if model.openThread != nil {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(ComposeMode.allCases) { m in
                            Text(m.label).tag(m).help(m.help)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help(model.mode.help)
                    .onChange(of: model.mode) { _, new in
                        if !model.isAvailable(new) { model.updateDefaultMode() }
                    }
                }

                Button {
                    model.send()
                } label: {
                    Image(systemName: model.isComposing ? "ellipsis" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(model.question.trimmingCharacters(in: .whitespaces).isEmpty || model.isComposing)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
        }
        .onChange(of: model.selection) { _, sel in
            if sel != nil { focused = true }
        }
    }

    private var placeholder: String {
        if model.selection != nil { return "Ask about this passage…" }
        if model.openThread != nil {
            switch model.mode {
            case .extend: return "Ask a follow-up…"
            case .rewrite: return "How should the answer change?"
            case .branch: return "Select another passage first"
            case .compose: return "Ask about the paper…"
            }
        }
        return "Select a passage, or ask about the whole paper…"
    }

    /// What the question is about, shown as a small token at the start of the bar.
    @ViewBuilder
    private var scopeToken: some View {
        let (icon, label): (String, String) = {
            if let sel = model.selection {
                let words = sel.text.split(separator: " ").prefix(4).joined(separator: " ")
                return ("text.quote", "“\(words)…”")
            }
            if model.openThread != nil, model.mode != .compose { return ("doc.richtext", "This answer") }
            return ("doc.text", "Whole paper")
        }()
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 220)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(model.selection?.text ?? "")
    }
}

/// Asks for the Claude API key once and keeps it in the Keychain.
struct APIKeySheet: View {
    let model: AppModel
    @State private var key = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude").font(.system(size: 20, weight: .bold))
            Text("Paste your Claude API key. It's saved in your Mac's Keychain and only sent to Anthropic.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Link("Get a key at platform.claude.com", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                .font(.system(size: 12))
            HStack {
                if APIKeyStore.read() != nil {
                    Button("Remove Saved Key", role: .destructive) {
                        APIKeyStore.delete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        APIKeyStore.save(k)
        model.errorMessage = nil
        dismiss()
        if !model.question.isEmpty { model.send() }
    }
}
