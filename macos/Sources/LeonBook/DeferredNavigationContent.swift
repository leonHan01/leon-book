import AppKit
import SwiftUI
import WebKit

struct NativeNavigationPageRequest: Hashable {
    let section: NativeSection
    let revision: UInt64
    let workspaceGeneration: Int
}

/// Mount only after the lightweight loading surface has had a display opportunity.
/// The destination closure stays unevaluated until then, including StateObjects,
/// sidebar lists, media views, and NSViewRepresentables such as WebKit.
@MainActor
struct NativeDeferredNavigationContent<Content: View>: View {
    let request: NativeNavigationPageRequest
    var sidebarWidth: CGFloat? = nil
    var waitForLoadingFrame: @MainActor () async throws -> Void = {
        // Yield through a display interval instead of starting heavy work from
        // onAppear/Task.yield, which can still run before the loading frame.
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    @ViewBuilder var content: (NativeNavigationPageRequest) -> Content
    @State private var mountedRequest: NativeNavigationPageRequest?

    var body: some View {
        let isReady = mountedRequest == request
        ZStack {
            // Retire the outgoing page after the loading frame as well. Its
            // snapshot must not follow the newly requested section underneath.
            if let mountedRequest, mountedRequest.workspaceGeneration == request.workspaceGeneration {
                content(mountedRequest)
                    .animation(nil, value: mountedRequest)
                    .opacity(isReady ? 1 : 0)
                    .allowsHitTesting(isReady)
                    .accessibilityHidden(!isReady)
            }
            NativeNavigationLoadingView(section: request.section, sidebarWidth: sidebarWidth, isActive: !isReady)
                .opacity(isReady ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(isReady)
        }
        .transaction { transaction in
            if !isReady {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .task(id: request) {
            do {
                try await waitForLoadingFrame()
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.12)) {
                    mountedRequest = request
                }
            } catch {
                // Changing destination/workspace or closing the window cancels
                // the pending mount. No superseded content should be constructed.
            }
        }
    }
}

struct NativeNavigationLoadingView: View {
    @Environment(\.nativeAppPalette) private var appPalette
    let section: NativeSection
    let sidebarWidth: CGFloat?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 0) {
            if let sidebarWidth {
                VStack(alignment: .leading, spacing: 16) {
                    skeleton(width: 110)
                    skeleton(width: 160)
                    skeleton(width: 130)
                    Spacer()
                }
                .padding(20)
                .frame(width: sidebarWidth + 6)
                .background(appPalette.sidebar)
                .clipShape(NativeWorkspaceSurfaceShape())
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    NativeNavigationLoadingSpinner(isAnimating: isActive)
                        .frame(width: 16, height: 16)
                    Text("正在加载…")
                        .font(.callout)
                        .foregroundStyle(appPalette.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(appPalette.canvas)
        .accessibilityIdentifier("navigation-loading")
    }

    private func skeleton(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(appPalette.surfaceSecondary)
            .frame(width: width, height: 12)
    }

    private var title: LocalizedStringKey {
        switch section {
        case .dashboard: return "概览"
        case .articles: return "全部文章"
        case .graph: return "关系图"
        case .canvas: return "无限画布"
        case .photos: return "相册"
        case .mediaLibrary: return "影音库"
        case .moments: return "微博"
        case .qAndA: return "问答"
        case .todos: return "待办"
        case .reader: return "阅读"
        case .editor: return "写作"
        case .trash: return "回收站"
        case .settings: return "设置"
        }
    }
}

/// Reuse one indicator per window; stop it whenever the destination is visible.
private struct NativeNavigationLoadingSpinner: NSViewRepresentable {
    let isAnimating: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = true
        indicator.usesThreadedAnimation = true
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
        guard context.coordinator.isAnimating != isAnimating else { return }
        context.coordinator.isAnimating = isAnimating
        if isAnimating {
            // The outgoing page remains alive for one display interval. End
            // its text focus now so typing cannot reach an invisible editor.
            if let window = indicator.window, let focused = window.firstResponder as? NSView,
               focused is NSTextView || sequence(first: focused, next: { $0.superview }).contains(where: { $0 is WKWebView }) {
                window.makeFirstResponder(nil)
            }
            indicator.startAnimation(nil)
        }
        else { indicator.stopAnimation(nil) }
    }

    static func dismantleNSView(_ indicator: NSProgressIndicator, coordinator: Coordinator) {
        indicator.stopAnimation(nil)
    }

    final class Coordinator {
        var isAnimating: Bool?
    }
}
