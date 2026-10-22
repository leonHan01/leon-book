import AppKit
import SwiftUI

/// Shared chrome colors. Reading themes and user-authored content keep their own colors.
enum NativeTheme {
    static let accent = adaptive(light: 0x3976CF, dark: 0x8ABCF8)
    static let buttonBlue = adaptive(light: 0x3976CF, dark: 0x3263A0)
    static let deepBlue = adaptive(light: 0x303238, dark: 0xE4E5E8)
    static let blue = adaptive(light: 0x3B6EAA, dark: 0x78A8E1)
    static let brandBlue = adaptive(light: 0x193B63, dark: 0x244D80)
    static let lightBlue = adaptive(light: 0xE8F1FC, dark: 0x243D5A)
    static let selection = adaptive(light: 0xEBEBED, dark: 0x35363A)
    static let rail = adaptive(light: 0xF3F3F4, dark: 0x202123)
    static let sidebar = adaptive(light: 0xFAFAFA, dark: 0x252628)
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1C1D1F)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x252628)
    static let surfaceSecondary = adaptive(light: 0xF5F5F6, dark: 0x2D2E31)
    static let border = adaptive(light: 0xE9E9EB, dark: 0x3A3B3E)
    static let textPrimary = adaptive(light: 0x303238, dark: 0xE4E5E8)
    static let textSecondary = adaptive(light: 0x85868C, dark: 0xA1A2A8)
    static let shadow = Color.black

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    func nativePrimaryButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(NativeTheme.buttonBlue)
            .foregroundStyle(.white)
    }

    func nativeAppTheme() -> some View {
        self
            .accentColor(NativeTheme.accent)
            .tint(NativeTheme.accent)
            .foregroundStyle(NativeTheme.textPrimary)
            .background(NativeTheme.canvas)
    }
}
