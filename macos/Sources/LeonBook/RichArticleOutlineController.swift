import SwiftUI
import WebKit

/// Connects the native directory to the current editor without moving its caret.
@MainActor
final class RichArticleOutlineController: ObservableObject {
    struct Snapshot: Equatable {
        var documentID = ""
        var items: [MarkdownOutlineItem] = []
        var activeID: String?
    }

    @Published private(set) var snapshot = Snapshot()
    private weak var webView: WKWebView?
    private var attachedDocumentID = ""

    func attach(to webView: WKWebView, documentID: String) {
        self.webView = webView
        attachedDocumentID = documentID
    }

    func detach(from webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
        attachedDocumentID = ""
    }

    func receive(items: [[String: Any]], documentID: String) {
        guard documentID == attachedDocumentID else { return }
        var seen = Set<String>()
        let headings = items.compactMap { item -> MarkdownOutlineItem? in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let level = item["level"] as? Int, (1...4).contains(level),
                  let title = item["title"] as? String, seen.insert(id).inserted else { return nil }
            return MarkdownOutlineItem(id: id, level: level, title: title)
        }
        let activeID = snapshot.documentID == documentID && headings.contains(where: { $0.id == snapshot.activeID }) ? snapshot.activeID : nil
        let next = Snapshot(documentID: documentID, items: headings, activeID: activeID)
        if snapshot != next { snapshot = next }
    }

    func receive(activeID: String, documentID: String) {
        guard documentID == attachedDocumentID, snapshot.documentID == documentID else { return }
        let next = snapshot.items.contains(where: { $0.id == activeID }) ? activeID : nil
        if snapshot.activeID != next { snapshot.activeID = next }
    }

    func navigate(to item: MarkdownOutlineItem, documentID: String) {
        guard attachedDocumentID == documentID, snapshot.documentID == documentID,
              snapshot.items.contains(where: { $0.id == item.id }) else { return }
        webView?.callAsyncJavaScript(
            "return window.LeonArticle.navigateOutline(headingID, documentID)",
            arguments: ["headingID": item.id, "documentID": documentID], in: nil, in: .page
        ) { _ in }
    }
}
