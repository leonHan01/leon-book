import AppKit
import SwiftUI

/// Fallback for AppKit helpers without a SwiftUI environment. Views use nativeAppPalette.
enum NativeTheme {
    static var current: NativeAppPalette {
        let defaults = UserDefaults.standard
        let theme = defaults.string(forKey: NativeAppearancePreferences.themeKey).flatMap(NativeColorTheme.init(rawValue:)) ?? .classic
        let appearance = defaults.string(forKey: NativeAppearancePreferences.appearanceKey).flatMap(NativeAppAppearance.init(rawValue:)) ?? .system
        let system: ColorScheme = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        return NativeAppPalette(theme: theme, colorScheme: appearance.preferredColorScheme ?? system)
    }
    static var textSecondary: Color { current.textSecondary }
    static var textPrimary: Color { current.textPrimary }
    static var blue: Color { current.blue }
    static var deepBlue: Color { current.deepBlue }
    static var accent: Color { current.accent }
    static var canvas: Color { current.canvas }
    static var surface: Color { current.surface }
    static var surfaceSecondary: Color { current.surfaceSecondary }
    static var border: Color { current.border }
}

extension View {
    func nativePrimaryButton() -> some View { modifier(NativePrimaryButtonModifier()) }

    @MainActor func nativeAppTheme(preferences: NativeAppearancePreferences? = nil) -> some View {
        modifier(NativeAppThemeModifier(preferences: preferences ?? .shared))
    }
}

private struct NativePrimaryButtonModifier: ViewModifier {
    @Environment(\.nativeAppPalette) private var appPalette
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).tint(appPalette.buttonBlue).foregroundStyle(.white)
    }
}

private struct NativeAppThemeModifier: ViewModifier {
    @ObservedObject var preferences: NativeAppearancePreferences
    @Environment(\.colorScheme) private var systemColorScheme

    func body(content: Content) -> some View {
        let palette = preferences.palette(system: systemColorScheme)
        content
            .environment(\.nativeAppPalette, palette)
            .environment(\.colorScheme, palette.colorScheme)
            .preferredColorScheme(preferences.appearance.preferredColorScheme)
            .accentColor(palette.accent)
            .tint(palette.accent)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(palette.textPrimary)
            .background(palette.canvas)
    }
}
