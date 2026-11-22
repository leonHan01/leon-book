import LeonBook
import LeonChat
import SwiftUI

@main
struct LeonBookApp: App {
    @NSApplicationDelegateAdaptor(LeonChatApplicationDelegate.self) private var chatDelegate
    @StateObject private var languagePreferences = NativeLanguagePreferences.shared

    var body: some Scene {
        WindowGroup("leon-book") {
            LeonBookWindowRoot()
                .environment(\.locale, languagePreferences.language.locale)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            LeonBookCommands()
        }

        Settings {
            LeonBookSettingsRoot()
                .environment(\.locale, languagePreferences.language.locale)
        }
    }
}

private struct LeonBookWindowRoot: View {
    @SceneStorage("leon-book.window-id") private var windowID = UUID().uuidString.lowercased()

    var body: some View {
        LeonBookWindowModelHost(windowID: windowID)
            .id(windowID)
    }
}

private struct LeonBookWindowModelHost: View {
    @StateObject private var model: NativeAppModel

    init(windowID: String) {
        _model = StateObject(wrappedValue: NativeAppModel(navigationScopeID: windowID))
    }

    var body: some View {
        ContentView(model: model)
    }
}

private struct LeonBookSettingsRoot: View {
    @StateObject private var model = NativeAppModel(navigationScopeID: "settings")

    var body: some View {
        NativeSettingsView(model: model)
    }
}

private struct LeonBookCommands: Commands {
    @FocusedObject private var model: NativeAppModel?
    @FocusedValue(\.leonChatActions) private var chatActions
    @ObservedObject private var preferences = NativeCommandPreferences.shared
    @ObservedObject private var languagePreferences = NativeLanguagePreferences.shared

    var body: some Commands {
        if let chatActions {
            CommandGroup(replacing: .appSettings) {
                Button(NativeLocalization.string("聊天设置…", language: languagePreferences.language), action: chatActions.openSettings)
                    .keyboardShortcut(",")
            }
            CommandMenu(NativeLocalization.string("聊天", language: languagePreferences.language)) {
                Button(NativeLocalization.string("立即同步", language: languagePreferences.language), action: chatActions.sync)
                    .keyboardShortcut("r")
            }
        }
        CommandMenu(NativeLocalization.string("笔记", language: languagePreferences.language)) {
            ForEach(menuCommands) { definition in
                Button(NativeLocalization.string(definition.title, language: languagePreferences.language)) {
                    model?.executeCommand(definition.id)
                }
                .modifier(NativeOptionalKeyboardShortcut(
                    shortcut: definition.id == .reload && chatActions != nil ? nil : preferences.shortcut(for: definition)
                ))
                .disabled(model?.canExecuteCommand(definition.id) != true)
            }
        }
    }

    private var menuCommands: [NativeCommandDefinition] {
        NativeCommandRegistry.builtIn.commands(
            on: .menu,
            context: model?.commandContext ?? NativeCommandContext(storageReady: false),
            includingUnavailable: true
        )
    }
}

private struct NativeOptionalKeyboardShortcut: ViewModifier {
    let shortcut: NativeCommandShortcut?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut, shortcut.isValid, let character = shortcut.key.first {
            content.keyboardShortcut(
                KeyEquivalent(character),
                modifiers: eventModifiers(for: shortcut.modifiers)
            )
        } else {
            content
        }
    }

    private func eventModifiers(
        for modifiers: Set<NativeCommandShortcut.Modifier>
    ) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}
