import AppKit
import SwiftUI
import WebKit
@testable import LeonBook

private struct ImageLoadingFailure: Error, CustomStringConvertible { let description: String }
private func imageExpect(_ value: Bool, _ message: String) throws {
    if !value { throw ImageLoadingFailure(description: message) }
}

/// Hold the actual encoding boundary while the main actor handles other work.
/// Never wait on the main thread, so a regression fails instead of deadlocking.
private final class ImageEncodingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var inputs: [Data] = []
    private var active = 0
    private var peak = 0
    private var usedMainThread = false
    private var timedOut = false

    var state: (inputs: [Data], peak: Int, mainThread: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (inputs, peak, usedMainThread, timedOut)
    }

    func release() { gate.signal() }

    func encode(_ data: Data) -> String? {
        lock.lock()
        inputs.append(data); active += 1; peak = max(peak, active)
        let first = inputs.count == 1
        usedMainThread = usedMainThread || Thread.isMainThread
        lock.unlock()
        if first && !Thread.isMainThread && gate.wait(timeout: .now() + 10) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
        }
        defer { lock.lock(); active -= 1; lock.unlock() }
        return RichArticleClipboard.imageDataURL(from: data)
    }
}

final class RichArticleImageLoadingTests {
    @MainActor private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ImageLoadingFailure(description: "image operation did not finish")
    }

    private func fixture(width: Int = 4, height: Int = 3) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 127, bitmap.bytesPerRow * height)
        return bitmap.tiffRepresentation!
    }

    @MainActor
    func testImageConversionIsBackgroundSerialAndCancellable() async throws {
        let data = fixture(width: 3200, height: 2400), probe = ImageEncodingProbe()
        let loader = RichArticleImageLoader(encode: { probe.encode($0) })
        defer { probe.release() }
        let first = Task { try await loader.imageDataURL(from: .clipboard([data])) }
        try await waitUntil { !probe.state.inputs.isEmpty }
        try imageExpect(!probe.state.mainThread, "image decoding/PNG encoding must not block the main thread")
        let skipped = Data("cancelled image must never decode".utf8)
        var queued = false
        let cancelled = Task { queued = true; return try await loader.imageDataURL(from: .clipboard([skipped])) }
        let next = Task { try await loader.imageDataURL(from: .clipboard([Data(), data])) }
        try await waitUntil { queued }
        cancelled.cancel()
        // The main actor reached here while the first decoder was held open.
        try imageExpect(probe.state.inputs.count == 1, "only one decoder may run across overlapping requests")
        probe.release()
        let result = try await first.value, fallback = try await next.value
        do { _ = try await cancelled.value; throw ImageLoadingFailure(description: "cancelled conversion completed") }
        catch is CancellationError { }
        try imageExpect(result == fallback, "invalid first format must fall back to a valid clipboard image")
        let png = Data(base64Encoded: String(result!.dropFirst("data:image/png;base64,".count)))!
        let image = NSBitmapImageRep(data: png)!
        try imageExpect(image.pixelsWide == 3200 && image.pixelsHigh == 2400, "conversion must preserve image dimensions")
        try imageExpect(probe.state.peak == 1 && !probe.state.inputs.contains(skipped) && !probe.state.timedOut,
                        "queued cancellation must skip conversion without overlapping decoders")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-loader-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let loaded = try await loader.imageDataURL(from: .file(file))
        try imageExpect(loaded == result, "replacement file must use the same image conversion")
        try FileManager.default.removeItem(at: file)
        do { _ = try await loader.imageDataURL(from: .file(file)); throw ImageLoadingFailure(description: "missing image file was accepted") }
        catch is CocoaError { }
        print("Image conversion: 3200×2400, main actor responsive during encoding; serial work and queued cancellation verified")
    }

    @MainActor
    func testNativeImagePastePreservesSnapshotCaretAndUndo() async throws {
        let pasteboard = NSPasteboard.withUniqueName(), original = fixture(), probe = ImageEncodingProbe()
        defer { probe.release(); pasteboard.releaseGlobally() }
        pasteboard.setData(original, forType: .tiff)
        try await withEditor { view, coordinator in
            coordinator.imagePasteboard = pasteboard
            coordinator.imageLoader = RichArticleImageLoader(encode: { probe.encode($0) })
            _ = try await view.evaluateJavaScript(#"""
            const root = document.getElementById('document');
            root.focus(); getSelection().setPosition(root.firstElementChild.firstChild, 2);
            root.dispatchEvent(new ClipboardEvent('paste', {clipboardData: new DataTransfer(), bubbles: true, cancelable: true}));
            """#)
            try await self.waitUntil { !probe.state.inputs.isEmpty }
            try imageExpect(!probe.state.mainThread, "native paste bridge must dispatch conversion off the UI thread")
            pasteboard.clearContents(); pasteboard.setData(self.fixture(width: 9), forType: .tiff)
            _ = try await view.evaluateJavaScript(#"""
            getSelection().setPosition(root.lastElementChild.firstChild, 2);
            document.execCommand('insertText', false, '新增');
            """#)
            probe.release()
            try await self.waitUntil { coordinator.parent.html.contains("data:image/png;base64,") }
            let source = RichArticleDocument.imageURLs(in: coordinator.parent.html).first!
            let png = Data(base64Encoded: String(source.dropFirst("data:image/png;base64,".count)))!
            try imageExpect(NSBitmapImageRep(data: png)?.pixelsWide == 4, "paste must use the original clipboard snapshot")
            _ = try await view.evaluateJavaScript(#"""
            if (!root.firstElementChild.querySelector('img') || root.lastElementChild.textContent !== '后文新增') throw new Error('pending paste lost its position or later typing');
            if (!root.lastElementChild.contains(getSelection().anchorNode)) throw new Error('paste stole the newer caret');
            LeonArticle.undo(-1);
            if (root.querySelector('img') || root.lastElementChild.textContent !== '后文新增') throw new Error('undo must remove only the completed image insertion');
            LeonArticle.undo(1);
            if (!root.firstElementChild.querySelector('img')) throw new Error('redo lost image');
            """#)
        }
    }

    @MainActor
    func testNativeImageRequestsRejectChangedOrClosedEditors() async throws {
        for reason in ["document", "workspace", "readonly", "dismantle"] {
            let probe = ImageEncodingProbe()
            defer { probe.release() }
            try await withEditor { view, coordinator in
                coordinator.imageLoader = RichArticleImageLoader(encode: { probe.encode($0) })
                _ = try await view.evaluateJavaScript(#"""
                window.imageCompletions = 0;
                LeonArticle.insertPastedImages = LeonArticle.completeImageReplacement = () => { imageCompletions++; return true; };
                true;
                """#)
                let first = coordinator.insertImage(from: .clipboard([self.fixture()]), requestID: "first", replacing: false, in: view)
                try await self.waitUntil { !probe.state.inputs.isEmpty }
                try imageExpect(!probe.state.mainThread, "pending image must leave the main actor available for navigation")
                let next = coordinator.insertImage(from: .clipboard([Data("obsolete".utf8)]), requestID: "next", replacing: true, in: view)
                let original = coordinator.parent
                switch reason {
                case "document":
                    coordinator.parent = RichArticleEditor(html: .constant("<p>另一篇</p>"), documentID: "other")
                case "workspace":
                    coordinator.parent.store = LocalBlogStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
                case "readonly": coordinator.parent.isEditable = false
                default: RichArticleEditor.dismantleNSView(view, coordinator: coordinator)
                }
                coordinator.parent = original // Returning to the same ID must not revive an old request.
                probe.release()
                await first.value; await next.value
                try imageExpect(first.isCancelled && next.isCancelled, "\(reason) must cancel running and queued image work")
                try imageExpect(probe.state.inputs.count == 1, "\(reason) must skip queued image decoding")
                let completions = try await view.evaluateJavaScript("imageCompletions") as? Int
                try imageExpect(completions == 0, "\(reason) allowed a stale image completion")
            }
        }
    }

    @MainActor private func withEditor(_ body: (WKWebView, RichArticleEditor.Coordinator) async throws -> Void) async throws {
        _ = NSApplication.shared
        var html = RichArticleDocument.opening + "<p>前文</p><p>后文</p></article>"
        let coordinator = RichArticleEditor.Coordinator(parent: RichArticleEditor(
            html: Binding(get: { html }, set: { html = $0 }), documentID: "image-loading-test"
        ))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        NativeWebLocalization.install(on: configuration, language: NativeLocalization.currentLanguage)
        configuration.userContentController.add(coordinator, name: "richArticle")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.navigationDelegate = coordinator
        defer { RichArticleEditor.dismantleNSView(view, coordinator: coordinator); window.close() }
        view.loadHTMLString(RichArticleEditor.pageHTML, baseURL: nil)
        try await waitUntil {
            (try? await view.evaluateJavaScript("document.getElementById('document')?.contentEditable === 'true'")) as? Bool == true
        }
        try await body(view, coordinator)
    }
}
