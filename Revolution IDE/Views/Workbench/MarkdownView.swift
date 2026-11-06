import SwiftUI

/// Renders Markdown: headings, paragraphs, lists (with task boxes), block quotes, fenced code, tables and rules.
/// Inline styling (bold, italic, code, links) comes from `AttributedString`'s Markdown parser.
struct MarkdownView: View {
	let text: String

	private enum Block {
		case heading(Int, String)
		case paragraph(String)
		case bullet(depth: Int, marker: String, text: String)
		case quote(String)
		case code(String)
		case table([[String]])
		case rule
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				let blocks = Self.parse(text)
				ForEach(blocks.indices, id: \.self) { view(for: blocks[$0]) }
			}
			.frame(maxWidth: 760, alignment: .leading)
			.frame(maxWidth: .infinity)
			.padding(24)
			.textSelection(.enabled)
		}
		.background(.background)
	}

	private static func inline(_ s: String) -> AttributedString {
		(try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
	}

	@ViewBuilder
	private func view(for block: Block) -> some View {
		switch block {
		case .heading(let level, let s):
			let size: CGFloat = [28, 22, 18, 16, 14, 13][min(level, 6) - 1]
			VStack(alignment: .leading, spacing: 4) {
				Text(Self.inline(s)).font(.system(size: size, weight: .bold)).padding(.top, level <= 2 ? 8 : 4)
				if level <= 2 { Divider() }
			}
		case .paragraph(let s):
			Text(Self.inline(s)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
		case .bullet(let depth, let marker, let s):
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
				Text(Self.inline(s)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
			}
			.padding(.leading, CGFloat(depth) * 20)
		case .quote(let s):
			Text(Self.inline(s)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
				.padding(10).frame(maxWidth: .infinity, alignment: .leading)
				.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
		case .code(let s):
			ScrollView(.horizontal) {
				Text(s).font(.system(size: 12, design: .monospaced)).padding(12)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
		case .table(let rows):
			Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
				ForEach(rows.indices, id: \.self) { r in
					GridRow {
						ForEach(rows[r].indices, id: \.self) { c in
							Text(Self.inline(rows[r][c])).fontWeight(r == 0 ? .semibold : .regular)
						}
					}
					if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
				}
			}
		case .rule:
			Divider().padding(.vertical, 4)
		}
	}

	// MARK: Parsing

	private static func parse(_ text: String) -> [Block] {
		var blocks: [Block] = []
		var paragraph: [String] = []
		var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
		func flush() {
			if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
		}
		while let raw = lines.popFirst() {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("```") || line.hasPrefix("~~~") {
				flush()
				var code: [String] = []
				while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix(String(line.prefix(3))) { code.append(next) }
				blocks.append(.code(code.joined(separator: "\n")))
			} else if line.isEmpty {
				flush()
			} else if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), h > line.startIndex, line.distance(from: line.startIndex, to: h) <= 6, line[h] == " " {
				flush()
				blocks.append(.heading(line.distance(from: line.startIndex, to: h), String(line[h...]).trimmingCharacters(in: .whitespaces)))
			} else if line.count >= 3, Set(line).isSubset(of: ["-", "*", "_", " "]), Set(line.filter { $0 != " " }).count == 1 {
				flush(); blocks.append(.rule)
			} else if line.hasPrefix(">") {
				flush()
				blocks.append(.quote(String(line.drop(while: { $0 == ">" || $0 == " " }))))
			} else if line.hasPrefix("|") {
				flush()
				var rows = [line]
				while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(lines.removeFirst().trimmingCharacters(in: .whitespaces)) }
				let cells = rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) } }
				blocks.append(.table(cells.filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty } }))
			} else if let item = listItem(raw) {
				flush(); blocks.append(item)
			} else {
				paragraph.append(line)
			}
		}
		flush()
		return blocks
	}

	private static func listItem(_ raw: String) -> Block? {
		let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
		let line = raw.trimmingCharacters(in: .whitespaces)
		var marker: String?, rest = ""
		if let f = line.first, "-*+".contains(f), line.dropFirst().first == " " { marker = "\u{2022}"; rest = String(line.dropFirst(2)) }
		else if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
			marker = String(line[...dot]); rest = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
		}
		guard var m = marker else { return nil }
		if rest.hasPrefix("[ ] ") { m = "\u{2610}"; rest = String(rest.dropFirst(4)) }
		else if rest.lowercased().hasPrefix("[x] ") { m = "\u{2611}"; rest = String(rest.dropFirst(4)) }
		return .bullet(depth: indent / 2, marker: m, text: rest)
	}
}
