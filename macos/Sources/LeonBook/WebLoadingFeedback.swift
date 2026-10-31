import AppKit
import WebKit

/// Web content paints independently from SwiftUI. Keep native feedback above
/// blank WebKit surfaces until navigation, or the document bridge, completes.
@MainActor
final class NativeLoadingWebView: WKWebView {
    var waitsForContent = false
    private(set) var loadingRequestID: UUID?
    private var loadingObservation: NSKeyValueObservation?
    private var loadingTimeout: Task<Void, Never>?
    private let loadingSurface = NativeWebLoadingSurface()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        loadingSurface.material = .popover
        loadingSurface.blendingMode = .withinWindow
        loadingSurface.wantsLayer = true
        loadingSurface.layer?.cornerRadius = 8
        loadingSurface.identifier = NSUserInterfaceItemIdentifier("web-loading-status")
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isIndeterminate = true
        loadingSpinner.usesThreadedAnimation = true
        loadingLabel.font = .systemFont(ofSize: 12)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [loadingSpinner, loadingLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingSurface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: loadingSurface.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: loadingSurface.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: loadingSurface.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: loadingSurface.bottomAnchor, constant: -9),
            loadingSpinner.widthAnchor.constraint(equalToConstant: 16),
            loadingSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        loadingObservation = observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            // WebKit delivers loading changes on its UI thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isLoading {
                    if self.loadingRequestID == nil { self.beginContentLoading() }
                } else if !self.waitsForContent {
                    self.finishContentLoading(self.loadingRequestID)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { loadingTimeout?.cancel() }

    @discardableResult
    func beginContentLoading(title: String = NativeLocalization.text("正在加载…")) -> UUID {
        let request = UUID()
        loadingRequestID = request
        loadingLabel.stringValue = title
        loadingSurface.setAccessibilityLabel(title)
        if loadingSurface.superview == nil {
            loadingSurface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(loadingSurface)
            NSLayoutConstraint.activate([
                loadingSurface.centerXAnchor.constraint(equalTo: centerXAnchor),
                loadingSurface.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                loadingSurface.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            ])
        }
        loadingSpinner.isHidden = false
        loadingSpinner.startAnimation(nil)
        loadingTimeout?.cancel()
        loadingTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            guard let self, self.loadingRequestID == request else { return }
            self.showLoadingFailure(NativeLocalization.text("加载时间较长，请重新打开此内容。"))
        }
        return request
    }

    func finishContentLoading(_ request: UUID?) {
        guard let request, loadingRequestID == request else { return }
        cancelLoadingFeedback()
    }

    func showLoadingFailure(_ message: String) {
        guard loadingRequestID != nil else { return }
        loadingTimeout?.cancel()
        loadingTimeout = nil
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        loadingLabel.stringValue = message
        loadingSurface.setAccessibilityLabel(message)
    }

    func cancelLoadingFeedback() {
        loadingTimeout?.cancel()
        loadingTimeout = nil
        loadingRequestID = nil
        loadingSpinner.stopAnimation(nil)
        loadingSurface.removeFromSuperview()
    }
}

private final class NativeWebLoadingSurface: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
