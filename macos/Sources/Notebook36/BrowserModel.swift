import AppKit
import Foundation
import Notebook36Core
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var siteURL: URL
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = "Notebook 36"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private weak var webView: WKWebView?
    private let localServer = LocalServerController()

    init(siteURL: URL = AppConfiguration.initialSiteURL) {
        self.siteURL = siteURL
    }

    var displayLocation: String {
        currentURL?.host ?? siteURL.host ?? siteURL.absoluteString
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        Task {
            do {
                try await localServer.ensureRunning(for: siteURL)
                loadHome()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadHome() {
        errorMessage = nil
        webView?.load(URLRequest(url: siteURL, cachePolicy: .reloadRevalidatingCacheData))
    }

    func reload() {
        errorMessage = nil
        if webView?.url == nil {
            loadHome()
        } else {
            webView?.reload()
        }
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func openCurrentPageInBrowser() {
        NSWorkspace.shared.open(currentURL ?? siteURL)
    }

    func updateSiteURL(_ rawValue: String) throws {
        guard let url = AppConfiguration.normalizedSiteURL(rawValue) else {
            throw SiteAddressError.invalid
        }

        siteURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: AppConfiguration.storedSiteURLKey)
        Task {
            do {
                try await localServer.ensureRunning(for: url)
                loadHome()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopLocalServer() {
        localServer.stop()
    }

    func navigationStarted() {
        isLoading = true
        errorMessage = nil
        refreshNavigationState()
    }

    func navigationFinished() {
        isLoading = false
        errorMessage = nil
        refreshNavigationState()
    }

    func navigationFailed(_ error: Error) {
        isLoading = false
        refreshNavigationState()

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        errorMessage = nsError.localizedDescription
    }

    private func refreshNavigationState() {
        guard let webView else { return }
        currentURL = webView.url
        pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Notebook 36"
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

enum SiteAddressError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "请输入有效的本机 HTTP 地址，例如 http://localhost:3000。"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
