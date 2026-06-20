import SwiftUI

// MARK: - Lightweight Markdown Renderer
//
// SwiftUI's `Text` only renders *inline* markdown (bold, italic, code,
// links). It flattens block elements (headings, lists, code blocks) onto
// a single line. This view parses the common block constructs the LLM
// produces and renders each as its own SwiftUI element — no external
// dependency required.

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
    }

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(number: String, text: String)
        case codeBlock(String)
        case paragraph(String)

        @ViewBuilder var view: some View {
            switch self {
            case .heading(let level, let text):
                MarkdownText.inline(text)
                    .font(headingFont(level))
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)

            case .bullet(let text):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    MarkdownText.inline(text)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .numbered(let number, let text):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(number).")
                        .fontWeight(.medium)
                        .monospacedDigit()
                    MarkdownText.inline(text)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .codeBlock(let code):
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appTertiaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)

            case .paragraph(let text):
                MarkdownText.inline(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func headingFont(_ level: Int) -> Font {
            switch level {
            case 1: return .title3
            case 2: return .headline
            default: return .subheadline
            }
        }
    }

    // MARK: - Inline rendering

    /// Renders inline markdown (bold, italic, `code`, links). Falls back to
    /// the raw string if parsing fails.
    static func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }

    // MARK: - Block parsing

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.components(separatedBy: "\n")

        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: "\n")))
            paragraphBuffer.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                i += 1 // skip closing fence
                continue
            }

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            // Bullet list item
            if let bulletText = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(text: bulletText))
                i += 1
                continue
            }

            // Numbered list item
            if let (number, text) = parseNumbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(number: number, text: text))
                i += 1
                continue
            }

            // Plain text → accumulate into a paragraph
            paragraphBuffer.append(trimmed)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> Block? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func parseNumbered(_ line: String) -> (String, String)? {
        // Matches "1. text", "12) text"
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard let digits = scanner.scanCharacters(from: .decimalDigits) else { return nil }
        guard let sep = scanner.scanCharacter(), sep == "." || sep == ")" else { return nil }
        guard scanner.scanCharacter() == " " else { return nil }
        let rest = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (digits, rest)
    }
}
