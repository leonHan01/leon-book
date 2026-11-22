@testable import LeonChat
import AppKit
import SwiftUI

@main
struct MathChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "MathChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func expressions(_ document: MessageMarkdown) -> [MathMarkup.Expression] {
        document.blocks.flatMap { block -> [MathMarkup.Expression] in
            if case .table = block.kind {
                return block.rows.flatMap { $0.flatMap { $0.runs.compactMap { $0[MathMarkup.Attribute.self] } } }
            }
            return block.text.runs.compactMap { $0[MathMarkup.Attribute.self] }
        }
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let latex = #"\text{Attention}(Q,K,V)=\text{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right)V"#
        let source = "这个过程通常写成：\n\\[\n\(latex)\n\\]\n\n不必记住公式，计算**相关性**。"
        let attention = MessageMarkdown(source)
        try check(attention.blocks.count == 3, "Display formula must be separated from surrounding prose")
        guard case .math(let formula) = attention.blocks[1].kind else { throw NSError(domain: "Missing display math", code: 1) }
        try check(formula.latex == latex && formula.display, "Attention LaTeX was changed by Markdown")
        try check(attention.blocks[2].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Bold after math lost")

        for input in [#"行内 $x_i^2$ 和 \(\frac{a}{b}\)"#,
                      "$$\nx_i^2\n$$\n\n\\[\\frac{a}{b}\\]",
                      "$$x_i^2$$\n\n\\[\n\\frac{a}{b}\n\\]",
                      "> \\[\n> x_i^2\n> \\]\n\n- \\(\\frac{a}{b}\\)",
                      #"| 数学 |"# + "\n| --- |\n" + #"| $x_i^2$ 和 \(\frac{a}{b}\) |"#] {
            let math = expressions(MessageMarkdown(input))
            try check(math.map(\.latex) == ["x_i^2", #"\frac{a}{b}"#], "Delimiter/container parsing failed: \(input)")
        }
        let quote = MessageMarkdown("> \\[\nx^2\n\\]")
        try check(quote.blocks.first?.quoteDepth == 1, "Math lost quote decoration")

        for input in [#"`$x_i$` 和 `\(x\)`"#, "```latex\n\\[\nx_i^2\n\\]\n$$x$$\n```",
                      "    $$x_i^2$$", #"价格 $5 和 $10，预算 US$20。"#, #"转义 \$x\$ 与 \\(x\\)"#,
                      #"未闭合 $x_i"#, "\\[\nx_i^2", "$$\nx_i^2",
                      #"[网站](https://example.com/$x$)"#,
                      "[网站][ref]\n\n[ref]: https://example.com/$x$",
                      "[\u{E000} $x$]\n\n[\u{E000} $x$]: https://example.com/path"] {
            try check(expressions(MessageMarkdown(input)).isEmpty, "Code, currency, links or incomplete math became a formula: \(input)")
        }
        try check(String(MessageMarkdown("\\[\nx_i^2").blocks[0].text.characters) == "\\[\nx_i^2", "Unclosed block math lost literal text")
        let unicode = MessageMarkdown("🚀 中文 $x_i$ 与 \u{E000}。")
        try check(String(unicode.blocks[0].text.characters) == "🚀 中文 $x_i$ 与 \u{E000}。", "Unicode or placeholder leaked")
        let link = MessageMarkdown(#"$x_i$ [网站](https://example.com/$x$)"#).blocks[0].text
        try check(link.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com/$x$"], "Math altered link destination")

        for latex in [latex, #"\sum_{i=1}^{n} x_i^2"#, #"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#] {
            let expression = MathMarkup.Expression(latex: latex, display: true, source: latex)
            for white in [false, true] {
                let rendered = MathRenderer.render(expression, white: white)
                try check(rendered != nil, "Native typesetting failed: \(latex)")
                guard let rendered else { continue }
                try check(rendered.image.size.width > 0 && rendered.image.size.height > 0, "Empty formula image")
                let small = rendered.fitting(width: 160)
                try check(small.image.size.width <= 160, "Wide formula was not scaled")
                try check(abs(small.image.size.width / small.image.size.height - rendered.image.size.width / rendered.image.size.height) < 0.001, "Formula aspect ratio changed")
                guard let cgImage = rendered.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw NSError(domain: "Unable to draw formula", code: 1)
                }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                var ink = false
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                        ink = true
                        break
                    }
                    if ink { break }
                }
                try check(ink, "Formula image contains no visible pixels")
            }
        }
        let invalid = MathMarkup.Expression(latex: #"\unknownLeonCommand{x}"#, display: false, source: #"\(\unknownLeonCommand{x}\)"#)
        try check(MathRenderer.render(invalid, white: false) == nil, "Invalid formula should fall back to source")

        // Offscreen preview exercises the same SwiftUI views, including inline image baselines.
        let preview = VStack(alignment: .leading, spacing: 18) {
            MarkdownMessageView(source, mine: false)
            MarkdownMessageView(#"行内：\(\frac{a}{b}\)，以及 $x_i^2$。"#, mine: false)
            MarkdownMessageView("$$\\begin{pmatrix}a & b \\\\ c & d\\end{pmatrix}$$", mine: true)
                .padding(12).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
        }.padding(24).frame(width: 580).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Math preview failed", code: 1)
        }
        try png.write(to: URL(fileURLWithPath: ".build/math-preview.png"))
        print("PASS: four math delimiters, inline/display layout, lists/quotes/tables, Unicode and Markdown compatibility")
        print("PASS: code/currency/link/escape preservation and incomplete/invalid formula fallback")
        print("PASS: native Attention/fraction/root/subscript/sum/matrix drawing, light/dark colors, proportional scaling and SwiftUI preview")
    }
}
