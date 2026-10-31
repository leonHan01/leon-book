import AppKit
import SwiftUI
import Vision
@testable import LeonBook

private struct WorkspaceChromeFailure: Error, CustomStringConvertible { let description: String }

final class WorkspaceChromeTests {
    @MainActor
    func testNavigationRailStaysFixedAcrossEveryDestination() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-rail-position-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: directory))
        let suiteName = "RailPositionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        model.firstPartyModuleRuntime = NativeFirstPartyModules.loadRuntime(defaults: defaults)
        defaults.removePersistentDomain(forName: suiteName)
        model.storageReady = true
        model.isLoading = false
        model.isDashboardLoaded = true
        model.section = .dashboard
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "rail-position-test")
        window.toolbar?.isVisible = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingController(rootView: ContentView(model: model)
            .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, .light))
        window.contentViewController = host
        defer { window.close() }

        func settle() async throws {
            for _ in 0..<4 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        // Measure the rendered icons, independent of SwiftUI's private view tree.
        // Exclude the light selected-button fill and the rail's trailing border.
        func iconCenters() throws -> [CGPoint] {
            host.view.layoutSubtreeIfNeeded()
            guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else {
                throw WorkspaceChromeFailure(description: "navigation rail snapshot unavailable")
            }
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            if let prefix = ProcessInfo.processInfo.environment["LEON_RAIL_PREVIEW"],
               model.section == .dashboard || model.section == .articles {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "\(prefix)-\(model.section).png"))
            }
            let scale = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
            var bands: [(start: Int, end: Int, minX: Int, maxX: Int)] = []
            for y in 0..<bitmap.pixelsHigh {
                var xs: [Int] = []
                for x in Int(14 * scale)..<Int(38 * scale) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9,
                          color.redComponent + color.greenComponent + color.blueComponent < 2.15 else { continue }
                    xs.append(x)
                }
                guard xs.count >= Int(2 * scale) else { continue }
                if let previous = bands.last, y - previous.end <= Int(6 * scale) {
                    bands[bands.count - 1] = (previous.start, y, min(previous.minX, xs.first!), max(previous.maxX, xs.last!))
                } else { bands.append((y, y, xs.first!, xs.last!)) }
            }
            let centers = bands.filter { CGFloat($0.end - $0.start) >= 7 * scale }.map {
                CGPoint(x: CGFloat($0.minX + $0.maxX) / (2 * scale), y: CGFloat($0.start + $0.end) / (2 * scale))
            }
            guard centers.count >= 9 else {
                throw WorkspaceChromeFailure(description: "could not locate navigation icons: \(centers)")
            }
            return centers
        }
        for size in [NSSize(width: 1080, height: 720), NSSize(width: 1280, height: 820)] {
            window.setContentSize(size)
            model.section = .dashboard
            window.toolbar?.isVisible = false
            try await settle()
            let baseline = try iconCenters()
            for section in [NativeSection.articles, .moments, .mediaLibrary, .dashboard, .photos,
                            .qAndA, .todos, .graph, .canvas, .reader, .editor, .trash, .settings, .dashboard] {
                model.section = section
                guard model.section == section else {
                    throw WorkspaceChromeFailure(description: "test did not navigate to \(section)")
                }
                // A raw NSHostingController does not let SwiftUI manage its
                // window toolbar as WindowGroup does. Reproduce the native
                // title-bar inset changes caused by optional toolbar items.
                window.toolbar?.isVisible = section.hasNavigationSidebar
                for phase in ["loading", "ready"] {
                    if phase == "ready" { try await settle() }
                    let positions = try iconCenters()
                    let drift = zip(baseline, positions).map { max(abs($0.x - $1.x), abs($0.y - $1.y)) }.max() ?? 0
                    print("RAIL_POSITION size=\(size) section=\(section) phase=\(phase) safeTop=\(host.view.safeAreaInsets.top) drift=\(drift)")
                    guard positions.count == baseline.count, drift <= 1 else {
                        throw WorkspaceChromeFailure(description: "navigation icons moved on \(section)/\(phase): \(baseline) -> \(positions)")
                    }
                }
            }
        }
    }

    @MainActor
    func testArticleHeaderStaysBelowWindowToolbar() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leon-workspace-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NativeAppModel(navigationScopeID: nil, startsAutomatically: false, store: LocalBlogStore(rootURL: directory))
        model.storageReady = true; model.isLoading = false; model.section = .articles
        // A stable ASCII folder title lets the fast local recognizer check the
        // rendered pixels. Offscreen SwiftUI does not expose an AX text tree.
        model.selectedArticleFolderPath = "Workspace"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "workspace-chrome-test")
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingController(rootView: ContentView(model: model)
            .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, .light))
        window.contentViewController = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<4 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        func snapshot() throws -> NSBitmapImageRep {
            guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else {
                throw WorkspaceChromeFailure(description: "workspace snapshot unavailable")
            }
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            return bitmap
        }
        for (size, toolbarVisible) in [
            (NSSize(width: 1080, height: 720), true),
            (NSSize(width: 1280, height: 820), true),
            (NSSize(width: 1440, height: 900), true),
            (NSSize(width: 1080, height: 720), false)
        ] {
            window.setContentSize(size)
            window.toolbar?.isVisible = toolbarVisible
            try await settle()
            guard let image = try snapshot().cgImage else { throw WorkspaceChromeFailure(description: "workspace image unavailable") }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesCPUOnly = true
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.regionOfInterest = CGRect(x: 0.18, y: 0.8, width: 0.82, height: 0.2)
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard let title = request.results?.first(where: { $0.topCandidates(1).first?.string == "Workspace" }) else {
                throw WorkspaceChromeFailure(description: "article title clipped at \(size), toolbar=\(toolbarVisible)")
            }
            // Vision reports fast-recognition bounds relative to the requested ROI.
            let topInset = (1 - request.regionOfInterest.maxY + (1 - title.boundingBox.maxY) * request.regionOfInterest.height) * host.view.bounds.height
            guard topInset >= host.view.safeAreaInsets.top else {
                throw WorkspaceChromeFailure(description: "article title intersects the title bar at \(size)")
            }
            print("WORKSPACE_HEADER size=\(size) toolbar=\(toolbarVisible) titleTop=\(topInset) safeTop=\(host.view.safeAreaInsets.top)")
        }
        // Optional Chinese preview of the same production header, for visual QA.
        if let output = ProcessInfo.processInfo.environment["LEON_WORKSPACE_PREVIEW"] {
            window.setContentSize(NSSize(width: 1280, height: 820)); window.toolbar?.isVisible = true
            model.selectedArticleFolderPath = nil
            try await settle()
            try snapshot().representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
    }
}
