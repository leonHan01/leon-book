import Foundation
import SwiftUI

@MainActor
final class AIReadingChat: ObservableObject {
    let store: LocalBlogStore
    let context: AIReadingContext
    let account: AIReadingAccountStore
    let client: any AIReadingServing
    @Published var configuration: AIReadingConfiguration
    @Published var messages: [AIReadingMessage] = []
    @Published var draft = ""
    @Published var streamingText = ""
    @Published var isLoading = true
    @Published var isSending = false
    @Published var error: String?
    @Published var exportedIDs = Set<String>()
    private(set) var sendTask: Task<Void, Never>?
    private var loaded = false

    init(store: LocalBlogStore, context: AIReadingContext, client: any AIReadingServing = AIReadingClient(),
         account: AIReadingAccountStore? = nil) {
        self.store = store; self.context = context; self.client = client
        self.account = account ?? AIReadingAccountStore(root: store.rootURL)
        configuration = self.account.load()
    }

    func load() async {
        guard !loaded else { return }
        do {
            messages = try await store.listAIReadingMessages(context: context)
            loaded = true
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    func send(context currentContext: AIReadingContext, key suppliedKey: String? = nil, retry: Bool = false) {
        guard !isSending, !isLoading, loaded, currentContext.identity == context.identity else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard retry ? messages.last?.role == .user : !text.isEmpty else { return }
        let config: AIReadingConfiguration
        let key: String
        do {
            config = try configuration.validated()
            key = try suppliedKey ?? account.key(for: config.provider)
            // Validate the entire request before saving or clearing the user's input.
            var preview = messages
            if !retry { preview.append(.init(role: .user, content: text, provider: config.provider, model: config.model)) }
            _ = try AIReadingClient.request(context: currentContext, messages: preview, configuration: config, key: key)
            try account.saveConfiguration(config)
        } catch { self.error = error.localizedDescription; return }
        isSending = true
        error = nil
        streamingText = ""
        sendTask = Task { [self] in
            defer { isSending = false; streamingText = ""; sendTask = nil }
            do {
                if !retry {
                    let message = AIReadingMessage(role: .user, content: text, provider: config.provider, model: config.model)
                    try await store.saveAIReadingMessage(message, context: context)
                    messages.append(message)
                    draft = ""
                }
                try Task.checkCancellation()
                let text = try await client.reply(context: currentContext, messages: messages, configuration: config, key: key) { [weak self] value in
                    self?.streamingText = value
                }
                try Task.checkCancellation()
                let reply = AIReadingMessage(role: .assistant, content: text, provider: config.provider, model: config.model)
                try await store.saveAIReadingMessage(reply, context: context)
                messages.append(reply)
            } catch {
                if !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let partial = AIReadingMessage(role: .assistant, content: streamingText, provider: config.provider,
                                                   model: config.model, isComplete: false)
                    do {
                        try await store.saveAIReadingMessage(partial, context: context)
                        messages.append(partial)
                    } catch { self.error = error.localizedDescription }
                }
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func stop() { sendTask?.cancel() }

    func clear() async {
        guard !isSending else { return }
        do {
            try await store.clearAIReadingMessages(context: context)
            messages = []; exportedIDs = []; error = nil
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
}
