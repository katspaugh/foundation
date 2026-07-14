// Builds data/wiki.db (SQLite FTS5) from a decompressed Wikipedia
// pages-articles XML dump. Run once:
//   swiftc -O indexer.swift -o indexer && ./indexer data/simplewiki-pages-articles.xml data/wiki.db
//
// Two passes: pass 1 counts incoming [[links]] per title (popularity signal
// for ranking), pass 2 cleans wikitext and writes the FTS index with a
// precomputed rank boost of log10(inlinks + 1).
import Foundation
import SQLite3

// MARK: - Wikitext -> plain text

enum Wikitext {
    private static let patterns: [(NSRegularExpression, String)] = {
        func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: opts)
        }
        return [
            (re("<!--.*?-->", [.dotMatchesLineSeparators]), " "),
            (re("<ref[^>]*/>"), " "),
            (re("<ref[^>]*>.*?</ref>", [.dotMatchesLineSeparators, .caseInsensitive]), " "),
            (re("\\{\\|.*?\\|\\}", [.dotMatchesLineSeparators]), " "),   // tables
            (re("<[^>]+>"), " "),                                        // html tags
            (re("\\[https?://[^ \\]]+ ([^\\]]+)\\]"), "$1"),             // ext link w/ label
            (re("\\[https?://[^\\]]+\\]"), " "),                         // bare ext link
            (re("'{2,}"), ""),                                           // bold/italic
            (re("^[=]{2,}\\s*(.*?)\\s*[=]{2,}\\s*$", [.anchorsMatchLines]), "$1."),
            (re("^[*#:;]+\\s*", [.anchorsMatchLines]), ""),              // list markers
        ]
    }()

    private static let template = try! NSRegularExpression(pattern: "\\{\\{[^{}]*\\}\\}",
                                                           options: [.dotMatchesLineSeparators])
    private static let link = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]]*)\\]\\]")
    private static let spaces = try! NSRegularExpression(pattern: "[ \\t]+")
    private static let blankLines = try! NSRegularExpression(pattern: "\\n{2,}")

    static func plainText(_ wikitext: String) -> String {
        var s = String(wikitext.prefix(16000))

        // Innermost-first template removal handles nesting.
        for _ in 0..<10 {
            let r = NSRange(s.startIndex..., in: s)
            let replaced = template.stringByReplacingMatches(in: s, range: r, withTemplate: " ")
            if replaced == s { break }
            s = replaced
        }

        for (regex, replacement) in patterns {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                               withTemplate: replacement)
        }

        // Innermost-first link resolution handles [[File:...[[nested]]...]].
        for _ in 0..<10 {
            let r = NSRange(s.startIndex..., in: s)
            let matches = link.matches(in: s, range: r)
            if matches.isEmpty { break }
            let ns = s as NSString
            var out = ""
            var cursor = 0
            for m in matches {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                let inner = ns.substring(with: m.range(at: 1))
                let lower = inner.lowercased()
                if lower.hasPrefix("file:") || lower.hasPrefix("image:") || lower.hasPrefix("category:") {
                    // drop media/category links entirely
                } else if let bar = inner.lastIndex(of: "|") {
                    out += String(inner[inner.index(after: bar)...])
                } else {
                    out += inner
                }
                cursor = m.range.location + m.range.length
            }
            out += ns.substring(from: cursor)
            s = out
        }

        s = s.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">")
             .replacingOccurrences(of: "&quot;", with: "\"")
             .replacingOccurrences(of: "&nbsp;", with: " ")
        s = spaces.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = blankLines.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
    }
}

// MARK: - Link counting (pass 1)

enum Links {
    static let regex = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]|#]+)(?:[|#][^\\[\\]]*)?\\]\\]")

    static func normalize(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first.isLowercase {
            t = first.uppercased() + t.dropFirst()
        }
        return t
    }

    static func targets(in wikitext: String) -> [String] {
        let ns = wikitext as NSString
        return regex.matches(in: wikitext, range: NSRange(location: 0, length: ns.length)).compactMap {
            let target = ns.substring(with: $0.range(at: 1))
            if target.contains(":") { return nil }  // File:, Category:, interwiki, …
            return normalize(target)
        }
    }
}

// MARK: - SQLite

final class Database {
    private var db: OpaquePointer?
    private var insert: OpaquePointer?
    private(set) var count = 0

    init(path: String) {
        unlink(path)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("Cannot create \(path)")
        }
        exec("PRAGMA journal_mode = OFF")
        exec("PRAGMA synchronous = OFF")
        exec("CREATE VIRTUAL TABLE articles USING fts5(title, body, boost UNINDEXED)")
        sqlite3_prepare_v2(db, "INSERT INTO articles (title, body, boost) VALUES (?, ?, ?)", -1, &insert, nil)
        exec("BEGIN")
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            fatalError("SQL error: \(err.map { String(cString: $0) } ?? "?") in \(sql)")
        }
    }

    func add(title: String, body: String, boost: Double) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(insert, 1, title, -1, transient)
        sqlite3_bind_text(insert, 2, body, -1, transient)
        sqlite3_bind_double(insert, 3, boost)
        sqlite3_step(insert)
        sqlite3_reset(insert)
        count += 1
        if count % 20000 == 0 {
            exec("COMMIT"); exec("BEGIN")
            print("\(count) articles indexed…")
        }
    }

    func finish() {
        exec("COMMIT")
        exec("INSERT INTO articles(articles) VALUES('optimize')")
        sqlite3_finalize(insert)
        sqlite3_close(db)
    }
}

// MARK: - Dump parsing

final class DumpParser: NSObject, XMLParserDelegate {
    // Pass 1: onPage is a link counter; pass 2: it indexes.
    let onPage: (_ title: String, _ ns: String, _ text: String, _ isRedirect: Bool) -> Void
    private var element = ""
    private var title = ""
    private var ns = ""
    private var text = ""
    private var isRedirect = false

    init(onPage: @escaping (String, String, String, Bool) -> Void) { self.onPage = onPage }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name
        switch name {
        case "page":
            title = ""; ns = ""; text = ""; isRedirect = false
        case "redirect":
            isRedirect = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch element {
        case "title": title += string
        case "ns": ns += string
        case "text": text += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        element = ""
        guard name == "page" else { return }
        onPage(title.trimmingCharacters(in: .whitespaces),
               ns.trimmingCharacters(in: .whitespaces), text, isRedirect)
    }
}

func parseDump(_ path: String, onPage: @escaping (String, String, String, Bool) -> Void) {
    guard let stream = InputStream(fileAtPath: path) else {
        print("Cannot open \(path)")
        exit(1)
    }
    let parser = XMLParser(stream: stream)
    let delegate = DumpParser(onPage: onPage)
    parser.delegate = delegate
    if !parser.parse() {
        print("XML parse error: \(parser.parserError?.localizedDescription ?? "unknown")")
        exit(1)
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: indexer <pages-articles.xml> <output.db>")
    exit(1)
}

let start = Date()

print("Pass 1: counting incoming links…")
var inlinks: [String: Int] = [:]
parseDump(args[1]) { _, ns, text, _ in
    guard ns == "0" else { return }
    for target in Links.targets(in: text) {
        inlinks[target, default: 0] += 1
    }
}
print("Pass 1 done: \(inlinks.count) distinct link targets in \(Int(Date().timeIntervalSince(start)))s")

print("Pass 2: building FTS index…")
let db = Database(path: args[2])
parseDump(args[1]) { title, ns, text, isRedirect in
    guard ns == "0", !isRedirect else { return }
    let body = Wikitext.plainText(text)
    guard body.count > 100 else { return }  // skip stubs/empty pages
    let boost = log10(Double(inlinks[Links.normalize(title)] ?? 0) + 1)
    db.add(title: title, body: body, boost: boost)
}
db.finish()
print("Done: \(db.count) articles in \(Int(Date().timeIntervalSince(start)))s -> \(args[2])")
