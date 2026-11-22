import SwiftUI
import AppKit

struct MarkdownMessageView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let source: String
    let mine: Bool
    var onQuote: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onBranch: (() -> Void)?

    init(_ source: String, mine: Bool, onQuote:(()->Void)? = nil, onFavorite:(()->Void)? = nil, onBranch:(()->Void)? = nil) {
        self.source = source
        self.mine = mine
        self.onQuote=onQuote;self.onFavorite=onFavorite;self.onBranch=onBranch
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source && lhs.mine == rhs.mine }

    var body: some View {
        if RichMarkdown.isRequired(source) {
            RichMarkdownMessageView(source: source, mine: mine, onQuote:onQuote,onFavorite:onFavorite,onBranch:onBranch)
        } else {
            nativeBody
        }
    }

    private var nativeBody: some View {
        let document = MessageMarkdown(source)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<block.quoteDepth, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2).fill(foreground.opacity(0.35)).frame(width: 3)
                    }
                    if let marker = block.marker {
                        Text(marker).font(.system(size: 14)).frame(minWidth: 16, alignment: .trailing)
                    }
                    content(block)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, CGFloat(block.indentation))
            }
        }
        .foregroundStyle(foreground)
        .tint(mine ? .white : .accentColor)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            MessageMarkdown.isAllowedLink(url) ? .systemAction : .discarded
        })
        .contextMenu {
            Button("复制原文") { copy(source) }
            if let onQuote {Button("引用",action:onQuote)}
            if let onFavorite {Button("收藏",action:onFavorite)}
                if let onBranch {Button("从这里创建分支",action:onBranch)}
        }
    }

    private var foreground: Color { mine ? .white : .primary }
    private var insetBackground: Color { mine ? .black.opacity(0.13) : .primary.opacity(0.055) }

    @ViewBuilder
    private func content(_ block: MessageMarkdown.Block) -> some View {
        switch block.kind {
        case .math(let expression):
            if let rendered = MathRenderer.render(expression, white: mine || colorScheme == .dark) {
                Image(nsImage: rendered.image).resizable().scaledToFit()
                    .frame(maxWidth: rendered.image.size.width)
                    .accessibilityLabel(expression.latex)
            } else {
                Text(expression.source).font(.system(size: 14, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Rectangle().fill(foreground.opacity(0.25)).frame(height: 1).padding(.vertical, 5)
        case .code(let language):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language ?? "代码").font(.system(size: 10, weight: .medium))
                    Spacer()
                    Button { copy(String(block.text.characters)) } label: {
                        Image(systemName: "doc.on.doc")
                    }.buttonStyle(.borderless).help("复制代码").accessibilityLabel("复制代码")
                }.foregroundStyle(foreground.opacity(0.75))
                ScrollView(.horizontal) {
                    Text(String(block.text.characters)).font(.system(size: 13, design: .monospaced))
                        .lineSpacing(4).fixedSize(horizontal: true, vertical: true)
                        .padding(.bottom, 4)
                }
            }.padding(10).background(insetBackground, in: RoundedRectangle(cornerRadius: 8))
        case .table:
            let widths = block.columns.indices.map { tableColumnWidth(block, column: $0) }
            ScrollView(.horizontal) {
                MarkdownTableLayout(widths: widths) {
                    ForEach(block.rows.indices, id: \.self) { row in
                        ForEach(block.columns.indices, id: \.self) { column in
                            mathText(styled(block.rows[row][column], size: 13, bold: row == 0), size: 13, maxWidth: widths[column] - 20)
                                .lineSpacing(3)
                                .frame(width: widths[column] - 20, alignment: alignment(block.columns[column].alignment))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(row == 0 ? insetBackground : .clear)
                                .overlay(Rectangle().stroke(foreground.opacity(0.18), lineWidth: 0.5))
                        }
                    }
                }.padding(1)
            }
        case .heading(let level):
            let size: CGFloat = [16, 15, 14, 14, 14, 14][min(max(level, 1), 6) - 1]
            mathText(styled(block.text, size: size, bold: true), size: size)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        case .text:
            mathText(styled(block.text)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tableColumnWidth(_ block: MessageMarkdown.Block, column: Int) -> CGFloat {
        // Horizontal scrolling proposes an unbounded width. Give every cell a
        // concrete wrapping width before measuring the height of its row.
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let contentWidth = block.rows.map { row in
            (String(row[column].characters) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return min(240, max(70, ceil(contentWidth) + 20))
    }

    private func mathText(_ source: AttributedString, size: CGFloat = 14, maxWidth: CGFloat = 400) -> Text {
        var result = Text("")
        for run in source.runs {
            if let expression = run[MathMarkup.Attribute.self],
               let rendered = MathRenderer.render(expression, size: size, white: mine || colorScheme == .dark)?.fitting(width: maxWidth) {
                result = Text("\(result)\(Text(Image(nsImage: rendered.image)).baselineOffset(-rendered.descent))")
            } else {
                result = Text("\(result)\(Text(AttributedString(source[run.range])))")
            }
        }
        return result
    }

    private func styled(_ source: AttributedString, size: CGFloat = 14, bold: Bool = false) -> AttributedString {
        var value = source
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = Font.system(size: size, design: intent.contains(.code) ? .monospaced : .default)
            if bold || intent.contains(.stronglyEmphasized) { font = font.bold() }
            if intent.contains(.emphasized) { font = font.italic() }
            value[run.range].font = font
            if intent.contains(.strikethrough) { value[run.range].strikethroughStyle = .single }
            if intent.contains(.code) { value[run.range].backgroundColor = insetBackground }
            if run.link != nil {
                value[run.range].foregroundColor = mine ? .white : .accentColor
                value[run.range].underlineStyle = .single
            }
        }
        return value
    }

    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch value {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        @unknown default: return .leading
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MarkdownTableLayout: Layout {
    let widths: [CGFloat]

    // Measurement and placement use the same row heights, keeping every cell
    // inside the table bounds reported to the surrounding message layout.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: widths.reduce(0, +), height: rowHeights(subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(subviews)
        var y = bounds.minY
        for row in heights.indices {
            var x = bounds.minX
            for column in widths.indices {
                let index = row * widths.count + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: widths[column], height: heights[row]))
                x += widths[column]
            }
            y += heights[row]
        }
    }

    private func rowHeights(_ subviews: Subviews) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + widths.count - 1) / widths.count)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: widths[index % widths.count], height: nil))
            heights[index / widths.count] = max(heights[index / widths.count], ceil(size.height))
        }
        return heights
    }
}
