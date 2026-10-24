import AppKit
import SwiftUI

enum NativeColorTheme: String, CaseIterable, Identifiable {
    case classic, forest, sand, lavender, graphite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "经典蓝"
        case .forest: return "松林绿"
        case .sand: return "暖沙棕"
        case .lavender: return "雾紫"
        case .graphite: return "石墨灰"
        }
    }
    var detail: String {
        switch self {
        case .classic: return "白色纸面，清爽蓝调"
        case .forest: return "柔和绿调，安静自然"
        case .sand: return "温暖纸色，沉稳棕调"
        case .lavender: return "淡雅紫调，轻盈柔和"
        case .graphite: return "中性灰阶，专注内容"
        }
    }
}

enum NativeAppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class NativeAppearancePreferences: ObservableObject {
    static let shared = NativeAppearancePreferences()
    nonisolated static let themeKey = "leon-book.color-theme.v1"
    nonisolated static let appearanceKey = "leon-book.app-appearance.v1"

    @Published var theme: NativeColorTheme {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var appearance: NativeAppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeKey).flatMap(NativeColorTheme.init(rawValue:)) ?? .classic
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(NativeAppAppearance.init(rawValue:)) ?? .system
    }

    func palette(system: ColorScheme) -> NativeAppPalette {
        NativeAppPalette(theme: theme, colorScheme: appearance.preferredColorScheme ?? system)
    }
}

/// A value in the SwiftUI environment makes every color consumer update in place.
/// Theme changes never recreate the workspace or its editor state.
struct NativeAppPalette: Equatable {
    let theme: NativeColorTheme
    let colorScheme: ColorScheme
    var isDark: Bool { colorScheme == .dark }

    func hex(_ role: Role) -> UInt32 {
        let dark = isDark
        switch (theme, role) {
        case (.classic, .accent): return dark ? 0x8ABCF8 : 0x3976CF
        case (.classic, .button): return dark ? 0x3263A0 : 0x3976CF
        case (.classic, .accentSoft): return dark ? 0x243D5A : 0xE8F1FC
        case (.forest, .accent): return dark ? 0x96CEAD : 0x317451
        case (.forest, .button): return dark ? 0x356E50 : 0x317451
        case (.forest, .accentSoft): return dark ? 0x263F32 : 0xE7F2EA
        case (.sand, .accent): return dark ? 0xE2BC8D : 0x91602F
        case (.sand, .button): return dark ? 0x876035 : 0x91602F
        case (.sand, .accentSoft): return dark ? 0x453727 : 0xF4EADB
        case (.lavender, .accent): return dark ? 0xC3B1EC : 0x7855AD
        case (.lavender, .button): return dark ? 0x705097 : 0x7855AD
        case (.lavender, .accentSoft): return dark ? 0x3B304C : 0xF0EAF8
        case (.graphite, .accent): return dark ? 0xCACCD3 : 0x565B66
        case (.graphite, .button): return dark ? 0x5D6370 : 0x565B66
        case (.graphite, .accentSoft): return dark ? 0x383B42 : 0xEAEBEE
        case (.forest, .canvas): return dark ? 0x1B201D : 0xFDFEFC
        case (.forest, .rail): return dark ? 0x222A25 : 0xEFF3EE
        case (.forest, .surface): return dark ? 0x252D28 : 0xFFFFFF
        case (.forest, .soft): return dark ? 0x2C352F : 0xF2F5F0
        case (.forest, .border): return dark ? 0x39463D : 0xE3EAE1
        case (.sand, .canvas): return dark ? 0x231F1A : 0xFFFCF6
        case (.sand, .rail): return dark ? 0x2C261F : 0xF2ECE1
        case (.sand, .surface): return dark ? 0x302920 : 0xFFFEFB
        case (.sand, .soft): return dark ? 0x393026 : 0xF6F0E5
        case (.sand, .border): return dark ? 0x4B4032 : 0xEAE1D2
        case (.lavender, .canvas): return dark ? 0x211D26 : 0xFEFCFF
        case (.lavender, .rail): return dark ? 0x292330 : 0xF2EEF6
        case (.lavender, .surface): return dark ? 0x302936 : 0xFFFFFF
        case (.lavender, .soft): return dark ? 0x38303F : 0xF6F2F9
        case (.lavender, .border): return dark ? 0x473D51 : 0xE9E2F0
        case (_, .canvas): return dark ? 0x1C1D1F : 0xFFFFFF
        case (_, .rail): return dark ? 0x202123 : 0xF3F3F4
        case (_, .surface): return dark ? 0x252628 : 0xFFFFFF
        case (_, .soft): return dark ? 0x2D2E31 : 0xF5F5F6
        case (_, .border): return dark ? 0x3A3B3E : 0xE9E9EB
        case (_, .text): return dark ? 0xE4E5E8 : 0x303238
        case (_, .muted): return dark ? 0xA1A2A8 : 0x85868C
        case (_, .selection): return dark ? 0x35363A : 0xEBEBED
        }
    }

    enum Role: String, CaseIterable { case accent, button, accentSoft, canvas, rail, surface, soft, border, text, muted, selection }
    func color(_ role: Role) -> Color { Color(nsColor: nsColor(role)) }
    func nsColor(_ role: Role) -> NSColor {
        let value = hex(role)
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var accent: Color { color(.accent) }
    var buttonBlue: Color { color(.button) }
    var deepBlue: Color { textPrimary }
    var blue: Color { accent }
    var brandBlue: Color { color(.button) }
    var lightBlue: Color { color(.accentSoft) }
    var selection: Color { color(.selection) }
    var rail: Color { color(.rail) }
    var canvas: Color { color(.canvas) }
    var sidebar: Color { canvas }
    var surface: Color { color(.surface) }
    var surfaceSecondary: Color { color(.soft) }
    var border: Color { color(.border) }
    var textPrimary: Color { color(.text) }
    var textSecondary: Color { color(.muted) }
    var shadow: Color { .black }

    var webColors: [String: String] {
        Dictionary(uniqueKeysWithValues: Role.allCases.map { ($0.rawValue, String(format: "#%06X", hex($0))) })
    }
}

private struct NativeAppPaletteKey: EnvironmentKey {
    static let defaultValue = NativeAppPalette(theme: .classic, colorScheme: .light)
}

extension EnvironmentValues {
    var nativeAppPalette: NativeAppPalette {
        get { self[NativeAppPaletteKey.self] }
        set { self[NativeAppPaletteKey.self] = newValue }
    }
}
