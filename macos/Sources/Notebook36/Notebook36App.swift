import SwiftUI

@main
struct Notebook36App: App {
    @StateObject private var browser = BrowserModel()

    var body: some Scene {
        WindowGroup("Notebook 36") {
            ContentView(model: browser)
                .onDisappear(perform: browser.stopLocalServer)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("浏览") {
                Button("后退", action: browser.goBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!browser.canGoBack)
                Button("前进", action: browser.goForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!browser.canGoForward)
                Divider()
                Button("刷新", action: browser.reload)
                    .keyboardShortcut("r", modifiers: .command)
                Button("博客首页", action: browser.loadHome)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("在默认浏览器中打开", action: browser.openCurrentPageInBrowser)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: browser)
        }
    }
}
