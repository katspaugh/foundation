import SwiftUI
import FoundationModels
import SQLite3

// MARK: - Local Wikipedia index (SQLite FTS5, built by indexer.swift)

final class WikiIndex: @unchecked Sendable {
    static let shared = WikiIndex()

    private let db: OpaquePointer?
    let articleCount: Int

    private init() {
        // Look next to the .app bundle first (project layout), then in the project dir.
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data/wiki.db").path,
            NSString("~/Sites/foundation/data/wiki.db").expandingTildeInPath,
        ]
        var handle: OpaquePointer?
        var count = 0
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(handle, "SELECT count(*) FROM articles", -1, &stmt, nil) == SQLITE_OK,
                   sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
                break
            }
            handle = nil
        }
        db = handle
        articleCount = count
    }

    var isAvailable: Bool { db != nil }

    struct Result {
        let title: String
        let lede: String
        let snippet: String
    }

    func search(_ query: String, limit: Int = 3) -> [Result] {
        guard let db else { return [] }
        let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        // Quoted terms keep FTS5 syntax characters in user text from breaking the query.
        let andQuery = words.map { "\"\($0)\"" }.joined(separator: " ")
        let orQuery = words.map { "\"\($0)\"" }.joined(separator: " OR ")

        // bm25() is negative-is-better; subtracting the popularity boost
        // (log10 of incoming link count, precomputed by the indexer) keeps
        // major articles ahead of obscure ones that merely repeat the terms.
        let sql = """
            SELECT title, substr(body, 1, 400), snippet(articles, 1, '', '', ' … ', 32)
            FROM articles WHERE articles MATCH ?
            ORDER BY bm25(articles, 10.0, 1.0) - 3.0 * boost LIMIT \(limit)
            """
        for match in [andQuery, orQuery] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, match, -1, transient)

            var results: [Result] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(Result(
                    title: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                    lede: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    snippet: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                ))
            }
            if !results.isEmpty { return results }  // AND matched; skip OR fallback
        }
        return []
    }
}

// MARK: - Foundation Models tool

// The 3B model sometimes gets stuck re-calling the tool with ever-growing
// queries until it overflows its 4k context. A hard per-prompt budget breaks
// that loop: past the limit (or on a repeated query) the tool tells the model
// to answer with what it already has.
final class ToolCallBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0
    private var lastQuery = ""

    func reset(_ calls: Int) {
        lock.withLock { remaining = calls; lastQuery = "" }
    }

    /// Returns true if this call is allowed.
    func allow(query: String) -> Bool {
        lock.withLock {
            if query == lastQuery { return false }
            lastQuery = query
            remaining -= 1
            return remaining >= 0
        }
    }
}

struct WikipediaSearchTool: Tool {
    let budget: ToolCallBudget

    let name = "searchWikipedia"
    let description = """
        Searches a local offline copy of Simple English Wikipedia and returns extracts \
        from the most relevant articles. Use it to verify factual claims or answer \
        factual questions.
        """

    @Generable
    struct Arguments {
        @Guide(description: "A few search keywords naming the main subject, e.g. 'Eiffel Tower height'")
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard budget.allow(query: arguments.query) else {
            return "You have already searched. Do NOT call searchWikipedia again. " +
                   "Answer the user now using the extracts you already received."
        }
        let results = WikiIndex.shared.search(arguments.query)
        guard !results.isEmpty else {
            return "No Wikipedia articles matched '\(arguments.query)'. Try different keywords."
        }
        return results.enumerated().map { index, r in
            index == 0
                ? "Article: \(r.title)\n\(r.lede)\nRelevant passage: \(r.snippet)"
                : "Article: \(r.title)\nRelevant passage: \(r.snippet)"
        }.joined(separator: "\n\n")
    }
}

func makeSession(budget: ToolCallBudget) -> LanguageModelSession {
    guard WikiIndex.shared.isAvailable else { return LanguageModelSession() }
    return LanguageModelSession(tools: [WikipediaSearchTool(budget: budget)], instructions: """
        You are a fact-checking assistant. You have a searchWikipedia tool backed by a \
        local copy of Simple English Wikipedia. For any factual claim or question from \
        the user, call searchWikipedia ONCE with keywords for the main subject, then \
        answer based on the returned extracts, naming the article(s) you relied on. \
        If the extracts don't contain the answer, say the local Wikipedia copy doesn't \
        settle it — do not guess.
        """)
}

// MARK: - UI

struct ContentView: View {
    @State private var prompt = ""
    @State private var response = ""
    @State private var errorMessage: String?
    @State private var isQuerying = false
    private static let budget = ToolCallBudget()
    @State private var session = makeSession(budget: ContentView.budget)

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
                Button("New Session") {
                    session = makeSession(budget: ContentView.budget)
                    response = ""
                    errorMessage = nil
                }
                .disabled(isQuerying)
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
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(response)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            Text(WikiIndex.shared.isAvailable
                 ? "Wikipedia fact-checking: \(WikiIndex.shared.articleCount) articles indexed"
                 : "Wikipedia index not found — run ./indexer (see README). Queries go to the bare model.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isQuerying = true
        errorMessage = nil
        response = ""
        Task {
            // The on-device model occasionally aborts mid-generation
            // (tokengeneration error 10); one retry usually recovers.
            for attempt in 1...2 {
                ContentView.budget.reset(2)
                do {
                    // Stream so the response appears as it's generated.
                    let stream = session.streamResponse(to: text)
                    for try await partial in stream {
                        response = partial.content
                    }
                    errorMessage = nil
                    break
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                    errorMessage = "The session ran out of context (4,096 tokens). Start a New Session."
                    break
                } catch {
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
