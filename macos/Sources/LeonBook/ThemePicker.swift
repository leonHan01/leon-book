import SwiftUI

struct NativeThemePicker: View {
    @Binding var selection: NativeColorTheme
    let colorScheme: ColorScheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
            ForEach(NativeColorTheme.allCases) { theme in
                Button { selection = theme } label: {
                    NativeThemePreview(theme: theme, colorScheme: colorScheme, isSelected: selection == theme)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(theme.title)))
                .accessibilityValue(Text(LocalizedStringKey(selection == theme ? "已选中" : "未选中")))
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
                .help(Text(LocalizedStringKey(theme.detail)))
            }
        }
        .padding(.vertical, 8)
    }
}

struct NativeThemePreview: View {
    let theme: NativeColorTheme
    let colorScheme: ColorScheme
    var isSelected = false

    private var palette: NativeAppPalette { NativeAppPalette(theme: theme, colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(palette.textSecondary.opacity(0.45)).frame(width: 4, height: 4) }
                    Spacer()
                }.padding(8).frame(height: 22).background(palette.rail)
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        NativeIcon.image("house", size: 10)
                        NativeIcon.image("doc.text", size: 10).foregroundStyle(palette.accent)
                        NativeIcon.image("photo", size: 10)
                        Spacer(minLength: 0)
                    }.foregroundStyle(palette.textSecondary).padding(.top, 10).frame(width: 24).background(palette.rail)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 32, height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(palette.lightBlue).frame(height: 13)
                        ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 2).fill(palette.border).frame(height: 4) }
                        Spacer(minLength: 0)
                    }.padding(10).frame(width: 62)
                    Rectangle().fill(palette.border).frame(width: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.textPrimary.opacity(0.7)).frame(width: 35, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(palette.surfaceSecondary).frame(height: 10)
                        ForEach(0..<2) { _ in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 3).fill(palette.lightBlue).frame(width: 13, height: 13)
                                RoundedRectangle(cornerRadius: 2).fill(palette.border).frame(height: 4)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 84).background(palette.canvas)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border, lineWidth: 1))
            HStack(spacing: 6) {
                Text(LocalizedStringKey(theme.title)).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if isSelected { NativeIcon.image("checkmark.circle", size: 14).foregroundStyle(palette.accent) }
            }.foregroundStyle(palette.textPrimary)
        }
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isSelected ? palette.accent : palette.border, lineWidth: isSelected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}
