import AppKit

/// What a text item holds: plain text, code, Markdown or a color value.
/// Worked out once when the item is saved and stored with it.
enum TextStyle: Int {
    case plain, code, markdown, color

    init(_ text: String) {
        let sample = String(text.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.color(from: sample) != nil || Self.matches(Self.colorPattern, sample) {
            self = .color
        } else if Self.isMarkdown(sample) {
            self = .markdown
        } else if Self.isCode(sample) {
            self = .code
        } else {
            self = .plain
        }
    }

    /// The color a hex or rgb()/rgba() value describes, for the swatch.
    static func color(from text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "ff" }
            guard let number = UInt64(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat(number >> 24 & 0xFF) / 255, green: CGFloat(number >> 16 & 0xFF) / 255,
                           blue: CGFloat(number >> 8 & 0xFF) / 255, alpha: CGFloat(number & 0xFF) / 255)
        }
        guard value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let parts = value[value.index(after: open)..<value.index(before: value.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255,
                       alpha: parts.count > 3 ? min(parts[3], 1) : 1)
    }

    private static let colorPattern = try! NSRegularExpression(pattern: #"^(rgba?|hsla?)\([^)]*\)$"#)

    /// Markdown needs two different signs, so a single "- item" list or a "# comment" stays plain.
    private static let markdownPatterns = [
        #"(?m)^#{1,6} \S"#, #"(?m)^\s*([-*+]|\d+\.) \S"#, #"(?m)^\s*[-*] \[[ xX]\] "#, #"(?m)^> "#,
        #"```"#, #"\[[^\]\n]+\]\([^)\s]+\)"#, #"\*\*[^*\n]+\*\*"#, #"(?m)^\|.+\|\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func isMarkdown(_ text: String) -> Bool {
        markdownPatterns.lazy.filter { matches($0, text) }.prefix(2).count == 2
    }

    private static let shellCommands: Set<String> = [
        "git", "gh", "npm", "npx", "yarn", "pnpm", "bun", "node", "deno", "brew", "cd", "ls", "mkdir", "rm", "mv",
        "cp", "cat", "grep", "rg", "find", "sed", "awk", "echo", "export", "chmod", "chown", "curl", "wget", "ssh",
        "scp", "rsync", "docker", "kubectl", "make", "cargo", "go", "swift", "xcodebuild", "python", "python3",
        "pip", "pip3", "php", "composer", "wp", "ruby", "gem", "bundle", "rails", "open", "tail", "head", "kill",
        "pkill", "ps", "tar", "zip", "unzip", "touch", "source", "defaults", "sqlite3", "psql", "mysql", "terraform",
    ]

    private static let keywordPattern = try! NSRegularExpression(pattern:
        #"\b(func|function|def|class|const|let|var|import|return|public|private|static|struct|enum|interface|fn|elif|SELECT|INSERT|UPDATE)\b"#)

    private static func isCode(_ text: String) -> Bool {
        let words = text.prefix { $0 != "\n" }.split(separator: " ")
        let command = words.first == "$" || words.first == "sudo" ? words.dropFirst().first : words.first
        if let command, shellCommands.contains(String(command)) { return true }
        if text.hasPrefix("<?php") || text.hasPrefix("#!") || text.hasPrefix("#include") { return true }
        if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) { return true }
        // Otherwise: dense with code symbols, plus a keyword or indented lines.
        let symbols = text.unicodeScalars.filter { "{}();=<>[]$|&".unicodeScalars.contains($0) }.count
        guard Double(symbols) / Double(max(text.count, 1)) > 0.03 else { return false }
        return matches(keywordPattern, text) || text.contains("\n    ") || text.contains("\n\t")
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
