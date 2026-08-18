import LeonBook
import SwiftUI

@main
struct LeonBookApp: App {
    @StateObject private var model = NativeAppModel()

    var body: some Scene {
        WindowGroup("leon-book") {
            ContentView(model: model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("笔记") {
                Button("新文章", action: model.newArticle)
                    .keyboardShortcut("n", modifiers: .command)
                Button("刷新文章", action: { Task { try? await model.reload() } })
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            NativeSettingsView(model: model)
        }
    }
}
