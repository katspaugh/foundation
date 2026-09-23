import Foundation
import FoundationModels

// isaac: the command-line version of FoundationChat. Same stateless queries
// as the app, with answers streamed to stdout.

let usage = """
    Usage: isaac [question ...]
           isaac --info

    Asks Apple's on-device Foundation Model. Given a question, prints the answer
    and exits. Without one, reads the question from piped stdin, or starts an
    interactive prompt in a terminal (Ctrl-D to quit). Each question is answered
    on its own, with no conversation history.

    Options:
      --info        Show model status
      -h, --help    Show this help
    """

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    warn("isaac: " + message)
    exit(code)
}

@main
struct Isaac {
    static func main() async {
        var showInfo = false
        var words: [String] = []

        var args = CommandLine.arguments.dropFirst()
        while let arg = args.popFirst() {
            switch arg {
            case "--info":
                showInfo = true
            case "-h", "--help":
                print(usage)
                exit(0)
            case "--":
                words += args
                args = []
            case _ where arg.hasPrefix("-") && arg != "-":
                fail("unknown option \(arg)\n\n\(usage)", code: 2)
            default:
                words.append(arg)
            }
        }

        let model = SystemLanguageModel.default

        if showInfo {
            switch model.availability {
            case .available:
                print("Model: \(Chat.modelSummary)")
            case .unavailable(let reason):
                print("Model: unavailable — \(Chat.unavailableMessage(reason))")
            }
            exit(0)
        }

        if case .unavailable(let reason) = model.availability {
            fail(Chat.unavailableMessage(reason), code: 3)
        }

        if !words.isEmpty {
            exit(await ask(words.joined(separator: " ")) ? 0 : 1)
        }

        if isatty(STDIN_FILENO) == 0 {
            let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { fail("no question given\n\n\(usage)", code: 2) }
            exit(await ask(input) ? 0 : 1)
        }

        print("FoundationChat — \(Chat.modelSummary). Ctrl-D to quit.")
        while true {
            print("\n> ", terminator: "")
            fflush(stdout)
            guard let line = readLine() else {
                print()
                break
            }
            let question = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                _ = await ask(question)
            }
        }
    }

    /// Streams one answer to stdout; errors go to stderr. Returns whether the
    /// query succeeded.
    @MainActor
    static func ask(_ question: String) async -> Bool {
        var printed = ""
        do {
            try await Chat.answer(
                question,
                onRetry: {
                    if !printed.isEmpty { print() }
                    printed = ""
                    warn("Generation failed, retrying…")
                },
                onPartial: { text in
                    // Each update is the whole response so far: print only
                    // what's new, or start over on the rare non-extending one.
                    if text.hasPrefix(printed) {
                        print(text.dropFirst(printed.count), terminator: "")
                    } else {
                        print("\n" + text, terminator: "")
                    }
                    fflush(stdout)
                    printed = text
                })
            print()
            return true
        } catch {
            if !printed.isEmpty { print() }
            warn(Chat.describe(error))
            return false
        }
    }
}
