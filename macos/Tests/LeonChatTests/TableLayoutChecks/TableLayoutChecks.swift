@testable import LeonChat
import AppKit
import SwiftUI
import Vision

@main
struct TableLayoutChecks {
    @MainActor
    static func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    static func checkFinalRowAndFollowingText() throws {
        let reason = "The recommendation must wrap across multiple lines so that every word remains visible in the table."
        let rows = (1...6).map { "| Song \($0) | \(reason)\($0 == 6 ? " LASTROW" : "") |" }.joined(separator: "\n")
        let source = "| Song | Recommendation |\n| --- | --- |\n" + rows + "\n\n**AFTERTABLE**"
        let content = MarkdownMessageView(source, mine: false).padding(16).frame(width: 500)
            .environment(\.colorScheme, .light).background(Color.white)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Missing table snapshot", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw NSError(domain: "Missing table image", code: 1) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        let last = observations.first { $0.topCandidates(1).first?.string.contains("LASTROW") == true }
        let following = observations.first { $0.topCandidates(1).first?.string.contains("AFTERTABLE") == true }
        guard let last, let following, last.boundingBox.minY > following.boundingBox.maxY else {
            throw NSError(domain: "TableLayoutChecks", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The final table row is clipped or overlaps the following paragraph"])
        }
    }

    @MainActor
    static func checkWrapping(_ text: String, width: CGFloat, header: Bool = false) throws {
        let source: (String) -> String = { value in
            header ? "| 歌曲 | \(value) |\n| --- | --- |\n| 天空之城 | 内容 |"
                : "| 歌曲 | 推荐理由 |\n| --- | --- |\n| 天空之城 | \(value) |"
        }
        let short = height(MarkdownMessageView(source("短文本"), mine: false).frame(width: width))
        let actual = height(MarkdownMessageView(source(text), mine: false).frame(width: width))
        let font = Font.system(size: 13, weight: header ? .bold : .regular)
        // A cell has at most 220 points of text inside its horizontal padding.
        // Rendering the complete text at that width gives a lower bound for its
        // row height, even if the table chooses a narrower column.
        let singleLine = height(Text("短文本").font(font).lineSpacing(3).frame(width: 220).fixedSize(horizontal: false, vertical: true))
        let completeText = height(Text(text).font(font).lineSpacing(3).frame(width: 220).fixedSize(horizontal: false, vertical: true))
        let required = short + completeText - singleLine
        guard actual >= required - 1 else {
            throw NSError(domain: "TableLayoutChecks", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Table truncates \(header ? "header" : "body") text at width \(width): height \(actual), requires at least \(required)"])
        }
    }

    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let chinese = "旋律容易进入，写爱情与失落，适合在安静的夜里独自聆听，配器简单而克制。完整的推荐理由应该自动换行，显示全部内容，并保留这一句的结尾。"
        let english = "A long recommendation should wrap inside the table cell and remain completely readable, including its final sentence rather than ending with an ellipsis."
        for width: CGFloat in [600, 280] {
            try checkWrapping(chinese, width: width)
            try checkWrapping(english, width: width)
            try checkWrapping(chinese, width: width, header: true)
        }
        try checkFinalRowAndFollowingText()
        print("PASS: Chinese and English table cells and long headers retain full multiline height in wide and narrow windows (6 checks)")
        print("PASS: rendered final-row text remains visible above the following paragraph")
    }
}
