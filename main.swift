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

    /// Searches for the given keywords with progressive relaxation: try all
    /// terms (AND), then drop the last term, and so on. This keeps a single
    /// stray keyword from hijacking the results the way a plain OR match would.
    func search(terms: [String], limit: Int = 3) -> [Result] {
        guard let db else { return [] }
        var clean: [String] = []
        for term in terms {
            for word in term.components(separatedBy: CharacterSet.alphanumerics.inverted)
            where word.count > 1 && !clean.contains(word.lowercased()) {
                clean.append(word.lowercased())
            }
        }
        guard !clean.isEmpty else { return [] }

        let sql = """
            SELECT title, substr(body, 1, 400), snippet(articles, 1, '', '', ' … ', 32)
            FROM articles WHERE articles MATCH ?
            ORDER BY bm25(articles, 10.0, 1.0) - 3.0 * boost LIMIT \(limit)
            """
        var count = clean.count
        while count >= 1 {
            let match = clean.prefix(count).map { "\"\($0)\"" }.joined(separator: " ")
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
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
                if !results.isEmpty { return results }
            }
            count -= 1
        }
        return []
    }
}

// MARK: - Retrieval-augmented answering

// Keywords the model pulls out of the question before we hit the index.
// Extracting the topical nouns first keeps framing words ("farthest", "most",
// "what") out of the search, which otherwise drag in unrelated articles.
@Generable
struct SearchTerms {
    @Guide(description: "2 to 4 lowercase keywords naming the core subject and named entities of the question. Nouns only. Omit question words, verbs like 'is'/'can', and comparison words like 'farthest'/'biggest'/'most'.")
    let terms: [String]
}

enum FactChecker {
    static func extractorSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You turn a user's question into search keywords for a Wikipedia \
            full-text index. Extract only the core subject nouns and named \
            entities. Drop framing words (what, how, farthest, most, biggest, \
            can, is).
            """)
    }

    static func answerSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            Answer the user's question using ONLY the provided Wikipedia extracts. \
            Cite the article titles you used. If the extracts are off-topic or \
            don't contain the answer, say the local Simple English Wikipedia \
            doesn't cover it — do NOT fall back on outside knowledge and do NOT \
            force an answer out of unrelated text.
            """)
    }

    static func plainSession() -> LanguageModelSession {
        LanguageModelSession()
    }

    static func format(_ results: [WikiIndex.Result]) -> String {
        results.map { "Article: \($0.title)\n\($0.lede)\nRelevant passage: \($0.snippet)" }
            .joined(separator: "\n\n")
    }
}

// MARK: - UI

struct ContentView: View {
    @State private var prompt = ""
    @State private var response = ""
    @State private var sources: [String] = []
    @State private var errorMessage: String?
    @State private var isQuerying = false
    @State private var useWikipedia = false

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
                Toggle("Fact-check with Wikipedia", isOn: $useWikipedia)
                    .toggleStyle(.checkbox)
                    .disabled(!WikiIndex.shared.isAvailable)
                    .help(WikiIndex.shared.isAvailable
                          ? "Retrieve extracts from local Simple English Wikipedia and answer from them."
                          : "Local Wikipedia index not found — run ./indexer (see README).")
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
                VStack(alignment: .leading, spacing: 10) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text(response)
                            .textSelection(.enabled)
                    }
                    if !sources.isEmpty {
                        Text("Sources: " + sources.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        isQuerying = true
        errorMessage = nil
        response = ""
        sources = []
        Task {
            // The on-device model occasionally aborts mid-generation
            // (tokengeneration error 10); one retry usually recovers.
            for attempt in 1...2 {
                do {
                    try await runQuery(question)
                    errorMessage = nil
                    break
                } catch is CancellationError {
                    break
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                    errorMessage = "The question retrieved too much text to fit the model's context. Try a narrower question."
                    break
                } catch {
                    response = ""
                    sources = []
                    errorMessage = attempt == 1
                        ? "Generation failed, retrying…"
                        : "Error: \(error.localizedDescription)"
                }
            }
            isQuerying = false
        }
    }

    private func runQuery(_ question: String) async throws {
        guard useWikipedia && WikiIndex.shared.isAvailable else {
            // Bare model: plain query, no retrieval.
            let stream = FactChecker.plainSession().streamResponse(to: question)
            for try await partial in stream { response = partial.content }
            return
        }

        // 1. Extract topical keywords, 2. retrieve, 3. answer grounded in extracts.
        let terms = try await FactChecker.extractorSession()
            .respond(to: question, generating: SearchTerms.self).content.terms
        let results = WikiIndex.shared.search(terms: terms)
        sources = results.map(\.title)

        let context = results.isEmpty
            ? "No matching Wikipedia articles were found."
            : FactChecker.format(results)
        let grounded = "Question: \(question)\n\nWikipedia extracts:\n\(context)"

        let stream = FactChecker.answerSession().streamResponse(to: grounded)
        for try await partial in stream { response = partial.content }
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
