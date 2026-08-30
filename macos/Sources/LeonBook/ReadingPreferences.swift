import AppKit
import Foundation
import SwiftUI

enum NativeReadingFontFamily: String, CaseIterable, Codable, Identifiable {
    case system
    case serif
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统字体"
        case .serif: return "衬线字体"
        case .rounded: return "圆体"
        }
    }

    func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system: return .system(size: size, weight: weight)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign?
        switch self {
        case .system: design = nil
        case .serif: design = .serif
        case .rounded: design = .rounded
        }
        guard let design,
              let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

enum NativeCodeFontFamily: String, CaseIterable, Codable, Identifiable {
    case system
    case menlo
    case monaco

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统等宽"
        case .menlo: return "Menlo"
        case .monaco: return "Monaco"
        }
    }

    func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size, design: .monospaced)
        case .menlo: return .custom("Menlo", size: size)
        case .monaco: return .custom("Monaco", size: size)
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch self {
        case .system: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .menlo: return NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        case .monaco: return NSFont(name: "Monaco", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }
}

enum NativeReadingTheme: String, CaseIterable, Codable, Identifiable {
    case system
    case paper
    case sepia
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .paper: return "纸张"
        case .sepia: return "暖褐"
        case .night: return "夜间"
        }
    }

    func colorScheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: return system
        case .paper, .sepia: return .light
        case .night: return .dark
        }
    }

    func background(system: ColorScheme) -> Color {
        switch self {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .paper: return Color(red: 0.975, green: 0.968, blue: 0.94)
        case .sepia: return Color(red: 0.93, green: 0.875, blue: 0.75)
        case .night: return Color(red: 0.075, green: 0.082, blue: 0.095)
        }
    }

    func codeBackground(system: ColorScheme) -> Color {
        switch self {
        case .system: return Color(nsColor: .textBackgroundColor)
        case .paper: return Color.black.opacity(0.045)
        case .sepia: return Color(red: 0.32, green: 0.24, blue: 0.13).opacity(0.09)
        case .night: return Color.white.opacity(0.065)
        }
    }
}

struct NativeReadingTypography: Equatable {
    var bodyFont: NativeReadingFontFamily
    var codeFont: NativeCodeFontFamily
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var theme: NativeReadingTheme

    static let `default` = NativeReadingTypography(
        bodyFont: .serif,
        codeFont: .system,
        fontSize: 18,
        lineSpacing: 6,
        paragraphSpacing: 16,
        theme: .system
    )
}

struct NativeReadingProfile: Codable, Equatable {
    var readingWidth: Double = 800
    var bodyFont: NativeReadingFontFamily = .serif
    var codeFont: NativeCodeFontFamily = .system
    var fontSize: Double = 18
    var lineSpacing: Double = 6
    var paragraphSpacing: Double = 16
    var theme: NativeReadingTheme = .system

    var normalized: Self {
        var result = self
        result.readingWidth = min(max(result.readingWidth, 520), 1_400)
        result.fontSize = min(max(result.fontSize, 13), 30)
        result.lineSpacing = min(max(result.lineSpacing, 0), 18)
        result.paragraphSpacing = min(max(result.paragraphSpacing, 4), 36)
        return result
    }

    var typography: NativeReadingTypography {
        NativeReadingTypography(
            bodyFont: bodyFont,
            codeFont: codeFont,
            fontSize: CGFloat(fontSize),
            lineSpacing: CGFloat(lineSpacing),
            paragraphSpacing: CGFloat(paragraphSpacing),
            theme: theme
        )
    }
}

@MainActor
final class NativeReadingPreferences: ObservableObject {
    private struct Archive: Codable {
        var profilesByUser: [String: NativeReadingProfile] = [:]
    }

    @Published var profile: NativeReadingProfile {
        didSet { profileDidChange() }
    }

    private let defaults: UserDefaults
    private let defaultsKey = "leon-book.reading-preferences.v1"
    private var archive: Archive
    private var currentUserID: String?
    private var isApplying = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
        profile = NativeReadingProfile()
    }

    var typography: NativeReadingTypography { profile.typography }

    func prepare(for userID: String) {
        reloadArchive()
        currentUserID = userID
        isApplying = true
        profile = (archive.profilesByUser[userID] ?? NativeReadingProfile()).normalized
        isApplying = false
    }

    func reset() {
        profile = NativeReadingProfile()
    }

    func applyPortableProfile(_ imported: NativeReadingProfile, for userID: String) {
        currentUserID = userID
        isApplying = true
        profile = imported.normalized
        isApplying = false
        archive.profilesByUser[userID] = profile
        persistArchive()
    }

    private func profileDidChange() {
        guard !isApplying else { return }
        let normalized = profile.normalized
        if normalized != profile {
            isApplying = true
            profile = normalized
            isApplying = false
        }
        guard let currentUserID else { return }
        archive.profilesByUser[currentUserID] = normalized
        persistArchive()
    }

    private func reloadArchive() {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        archive = stored
    }

    private func persistArchive() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

private struct NativeReadingTypographyKey: EnvironmentKey {
    static let defaultValue = NativeReadingTypography.default
}

extension EnvironmentValues {
    var nativeReadingTypography: NativeReadingTypography {
        get { self[NativeReadingTypographyKey.self] }
        set { self[NativeReadingTypographyKey.self] = newValue }
    }
}
