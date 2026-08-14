import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()

            ZStack {
                BlogWebView(model: model)

                if let errorMessage = model.errorMessage {
                    ConnectionErrorView(
                        address: model.siteURL.absoluteString,
                        message: errorMessage,
                        retry: model.reload,
                        openSettings: showSettings
                    )
                }
            }
        }
        .frame(minWidth: 840, minHeight: 620)
        .navigationTitle(model.pageTitle)
    }

    private var navigationBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help("后退")

                Button(action: model.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help("前进")

                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")

                Button(action: model.loadHome) {
                    Image(systemName: "house")
                }
                .help("博客首页")
            }
            .buttonStyle(.borderless)

            HStack(spacing: 8) {
                Image(systemName: model.siteURL.scheme == "https" ? "lock.fill" : "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.displayLocation)
                    .font(.system(.callout, design: .rounded))
                    .lineLimit(1)

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Button(action: model.openCurrentPageInBrowser) {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("在默认浏览器中打开")

            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置博客地址")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

private struct ConnectionErrorView: View {
    let address: String
    let message: String
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("无法连接到 Notebook 36")
                    .font(.title2.weight(.semibold))
                Text(address)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("设置地址", action: openSettings)
                Button("重试", action: retry)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 18, y: 8)
        .padding(40)
    }
}
