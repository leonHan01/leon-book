import AppKit
import SwiftUI

/// Shared chrome colors. Reading themes and user-authored content keep their own colors.
enum NativeTheme {
    static let accent = adaptive(light: 0x245FA6, dark: 0x8ABCF8)
    static let buttonBlue = adaptive(light: 0x245FA6, dark: 0x3263A0)
    static let deepBlue = adaptive(light: 0x193B63, dark: 0xC4DFFF)
    static let blue = adaptive(light: 0x3B6EAA, dark: 0x78A8E1)
    static let brandBlue = adaptive(light: 0x193B63, dark: 0x244D80)
    static let lightBlue = adaptive(light: 0xE8F1FC, dark: 0x243D5A)
    static let selection = adaptive(light: 0xD6E6F9, dark: 0x2C4B70)
    static let sidebar = adaptive(light: 0xEAF0F7, dark: 0x15253A)
    static let canvas = adaptive(light: 0xF3F6FA, dark: 0x101C2C)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B2C42)
    static let surfaceSecondary = adaptive(light: 0xEDF2F7, dark: 0x223349)
    static let border = adaptive(light: 0xD5E0EC, dark: 0x364B63)
    static let textPrimary = adaptive(light: 0x24364B, dark: 0xE4EDF7)
    static let textSecondary = adaptive(light: 0x62748A, dark: 0xA6B8CD)
    static let shadow = Color(red: 0.08, green: 0.17, blue: 0.29)

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
