import SwiftUI
import FoundationModels

struct ContentView: View {
    @State private var prompt = ""
    @State private var response = ""
    @State private var errorMessage: String?
    @State private var isQuerying = false

    private let model = SystemLanguageModel.default

    var body: some View {
        Group {
            switch model.availability {
            case .available:
                queryView
            case .unavailable(let reason):
                unavailableView(reason)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 520)
    }

    private var queryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(height: 48)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Button("Submit", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isQuerying || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isQuerying {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("⌘↩ to submit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Response")
                .font(.headline)
            ScrollView {
                Group {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text(response)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func unavailableView(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> some View {
        let message: String
        switch reason {
        case .deviceNotEligible:
            message = "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            message = "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
        case .modelNotReady:
            message = "The model is still downloading or preparing. Try again in a bit."
        @unknown default:
            message = "The model is unavailable for an unknown reason."
        }
        return ContentUnavailableView("Model Unavailable",
                                      systemImage: "exclamationmark.triangle",
                                      description: Text(message))
    }

    private func submit() {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        isQuerying = true
        errorMessage = nil
        response = ""
        Task {
            // The on-device model occasionally aborts mid-generation
            // (tokengeneration error 10); one retry usually recovers.
            for attempt in 1...2 {
                do {
                    let stream = LanguageModelSession().streamResponse(to: question)
                    for try await partial in stream { response = partial.content }
                    errorMessage = nil
                    break
                } catch is CancellationError {
                    break
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                    errorMessage = "The prompt is too long for the model's context. Try a shorter one."
                    break
                } catch {
                    response = ""
                    errorMessage = attempt == 1
                        ? "Generation failed, retrying…"
                        : "Error: \(error.localizedDescription)"
                }
            }
            isQuerying = false
        }
    }
}

// Minimal main menu so Cmd+Q, copy/paste, and undo work in the text views.
func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit FoundationChat",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu

    return mainMenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = buildMainMenu()

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered,
                      defer: false)
window.title = "FoundationChat"
window.contentViewController = NSHostingController(rootView: ContentView())
window.center()
window.setFrameAutosaveName("FoundationChatMain")
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
