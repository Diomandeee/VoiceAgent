import Foundation
import ComposableArchitecture

// MARK: - Conversation History Manager (TCA Dependency)

struct ConversationHistoryManager: Sendable {
    /// Append a user message to the history.
    var appendUserMessage: @Sendable (_ content: String) -> Void

    /// Append an assistant message to the history.
    var appendAssistantMessage: @Sendable (_ content: String) -> Void

    /// Get the current conversation history as OpenAI-compatible message array.
    var getHistory: @Sendable () -> [[String: String]]

    /// Replace the entire history (used when switching threads).
    var setHistory: @Sendable (_ history: [[String: String]]) -> Void

    /// Trim history to a maximum number of turns (1 turn = 1 user + 1 assistant).
    var trimHistory: @Sendable (_ maxTurns: Int) -> Void

    /// Clear all history.
    var clearHistory: @Sendable () -> Void

    /// Set a context hint that will be prepended to the next user message.
    /// Used to inject Gemini observer insights.
    var setContextHint: @Sendable (_ hint: String) -> Void

    /// Get and consume the current context hint.
    var consumeContextHint: @Sendable () -> String?
}

// MARK: - Conversation History Store (thread-safe actor)

private actor ConversationHistoryStore {
    static let shared = ConversationHistoryStore()

    private var history: [[String: String]] = []
    private var contextHint: String?
    private let maxTurnsDefault = 10 // 10 turns = 20 messages

    func appendUser(_ content: String) {
        var message = content
        // Inject context hint if present
        if let hint = contextHint {
            message = "[\(hint)] \(content)"
            contextHint = nil
        }
        history.append(["role": "user", "content": message])
        trimIfNeeded()
    }

    func appendAssistant(_ content: String) {
        history.append(["role": "assistant", "content": content])
        trimIfNeeded()
    }

    func getHistory() -> [[String: String]] {
        return history
    }

    func setHistory(_ newHistory: [[String: String]]) {
        history = newHistory
    }

    func trimHistory(_ maxTurns: Int) {
        let maxMessages = maxTurns * 2
        if history.count > maxMessages {
            history = Array(history.suffix(maxMessages))
        }
    }

    func clearHistory() {
        history = []
        contextHint = nil
    }

    func setContextHint(_ hint: String) {
        contextHint = hint
    }

    func consumeContextHint() -> String? {
        let hint = contextHint
        contextHint = nil
        return hint
    }

    private func trimIfNeeded() {
        let maxMessages = maxTurnsDefault * 2
        if history.count > maxMessages {
            history = Array(history.suffix(maxMessages))
        }
    }
}

// MARK: - Live Implementation

extension ConversationHistoryManager: DependencyKey {
    static let liveValue: ConversationHistoryManager = {
        let store = ConversationHistoryStore.shared

        // These closures capture the actor and dispatch synchronously for the non-async API.
        // We use a lock-based cache to provide synchronous access while the actor is the source of truth.
        let cache = HistoryCache()

        return ConversationHistoryManager(
            appendUserMessage: { content in
                cache.appendUser(content)
                Task { await store.appendUser(content) }
            },
            appendAssistantMessage: { content in
                cache.appendAssistant(content)
                Task { await store.appendAssistant(content) }
            },
            getHistory: {
                cache.getHistory()
            },
            setHistory: { history in
                cache.setHistory(history)
                Task { await store.setHistory(history) }
            },
            trimHistory: { maxTurns in
                cache.trimHistory(maxTurns)
                Task { await store.trimHistory(maxTurns) }
            },
            clearHistory: {
                cache.clearHistory()
                Task { await store.clearHistory() }
            },
            setContextHint: { hint in
                cache.setContextHint(hint)
                Task { await store.setContextHint(hint) }
            },
            consumeContextHint: {
                cache.consumeContextHint()
            }
        )
    }()
}

/// Thread-safe synchronous cache for conversation history.
/// Provides immediate access while the actor-based store is the durable source of truth.
private final class HistoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [[String: String]] = []
    private var contextHint: String?
    private let maxTurns = 10

    func appendUser(_ content: String) {
        lock.lock()
        defer { lock.unlock() }
        var message = content
        if let hint = contextHint {
            message = "[\(hint)] \(content)"
            contextHint = nil
        }
        history.append(["role": "user", "content": message])
        trimIfNeeded()
    }

    func appendAssistant(_ content: String) {
        lock.lock()
        defer { lock.unlock() }
        history.append(["role": "assistant", "content": content])
        trimIfNeeded()
    }

    func getHistory() -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    func setHistory(_ newHistory: [[String: String]]) {
        lock.lock()
        defer { lock.unlock() }
        history = newHistory
    }

    func trimHistory(_ maxTurns: Int) {
        lock.lock()
        defer { lock.unlock() }
        let maxMessages = maxTurns * 2
        if history.count > maxMessages {
            history = Array(history.suffix(maxMessages))
        }
    }

    func clearHistory() {
        lock.lock()
        defer { lock.unlock() }
        history = []
        contextHint = nil
    }

    func setContextHint(_ hint: String) {
        lock.lock()
        defer { lock.unlock() }
        contextHint = hint
    }

    func consumeContextHint() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let hint = contextHint
        contextHint = nil
        return hint
    }

    private func trimIfNeeded() {
        let maxMessages = maxTurns * 2
        if history.count > maxMessages {
            history = Array(history.suffix(maxMessages))
        }
    }
}

extension DependencyValues {
    var conversationHistoryManager: ConversationHistoryManager {
        get { self[ConversationHistoryManager.self] }
        set { self[ConversationHistoryManager.self] = newValue }
    }
}
