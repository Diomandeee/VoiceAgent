import Foundation
import ComposableArchitecture
import OpenClawCore

// MARK: - Gateway Client (Clawdbot WS v3 protocol + REST proxy)

public struct GatewayClient: Sendable {
    public var sendAgentMessage: @Sendable (
        _ message: String,
        _ sessionKey: String?,
        _ model: String?,
        _ channelName: String?
    ) async throws -> GatewayResponse

    public var streamAgentMessage: @Sendable (
        _ message: String,
        _ sessionKey: String?,
        _ model: String?,
        _ channelName: String?
    ) -> AsyncStream<GatewayChunk>

    public var checkHealth: @Sendable () async -> GatewayStatus

    public var sendClawbotMessage: @Sendable (
        _ message: String,
        _ history: [[String: String]],
        _ sessionKey: String,
        _ channelName: String?,
        _ model: String?,
        _ voiceDispatch: Bool,
        _ imageData: Data?
    ) async throws -> String
}

// MARK: - Response types

public struct GatewayResponse: Codable, Equatable, Sendable {
    public let text: String
    public let model: String?
    public let sessionKey: String?
    public let tokenCount: Int?

    public init(text: String, model: String?, sessionKey: String?, tokenCount: Int?) {
        self.text = text
        self.model = model
        self.sessionKey = sessionKey
        self.tokenCount = tokenCount
    }
}

public struct GatewayChunk: Equatable, Sendable {
    public let text: String
    public let isComplete: Bool
    public let model: String?

    public init(text: String, isComplete: Bool, model: String?) {
        self.text = text
        self.isComplete = isComplete
        self.model = model
    }
}

public enum GatewayStatus: Equatable, Sendable {
    case connected
    case disconnected
    case error(String)
}

// MARK: - Model Heuristic

public enum ModelHeuristic {
    private static let claudeKeywords: Set<String> = [
        "debug", "implement", "fix", "refactor", "compile", "build", "deploy",
        "error", "crash", "bug", "code", "function", "class", "struct", "swift",
        "typescript", "rust", "python", "test", "lint", "pr", "commit"
    ]

    private static let geminiKeywords: Set<String> = [
        "research", "analyze", "summarize", "compare", "explain", "documentation",
        "docs", "article", "paper", "trend", "market", "report", "overview",
        "history", "context", "background", "literature", "review"
    ]

    public static func preferredModel(
        for text: String,
        category: ThreadCategory?,
        explicitChoice: String?
    ) -> String? {
        if let explicit = explicitChoice { return explicit }
        switch category {
        case .compCore, .pulseControl, .infrastructure: return "claude"
        case .research: return "gemini"
        default: break
        }
        if text.count > 8000 { return "gemini" }
        let words = Set(text.lowercased().split(separator: " ").map(String.init))
        let claudeScore = words.intersection(claudeKeywords).count
        let geminiScore = words.intersection(geminiKeywords).count
        if claudeScore > geminiScore && claudeScore >= 2 { return "claude" }
        if geminiScore > claudeScore && geminiScore >= 2 { return "gemini" }
        return nil
    }
}

// MARK: - Live Implementation

extension GatewayClient: DependencyKey {
    public static let liveValue = GatewayClient(
        sendAgentMessage: { message, sessionKey, model, channelName in
            let url = URL(string: "http://\(OpenClawConfig.gatewayHost):\(OpenClawConfig.gatewayProxyPort)/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            if let sessionKey { request.setValue(sessionKey, forHTTPHeaderField: "x-clawdbot-session-key") }
            if let channelName { request.setValue(channelName, forHTTPHeaderField: "x-clawdbot-channel-name") }

            let heuristic = model ?? ModelHeuristic.preferredModel(
                for: message,
                category: channelName.flatMap { name in ThreadCategory.allCases.first { $0.channelName == name } },
                explicitChoice: nil
            )
            if let pref = heuristic, model == nil {
                request.setValue(pref, forHTTPHeaderField: "x-clawdbot-model-preference")
            }

            var body: [String: Any] = [
                "messages": [["role": "user", "content": message]],
                "stream": false,
            ]
            if let model { body["model"] = model }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw GatewayError.httpError(statusCode, String(data: data, encoding: .utf8) ?? "")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let messageObj = choices?.first?["message"] as? [String: Any]
            let text = messageObj?["content"] as? String ?? ""
            let usedModel = json?["model"] as? String

            return GatewayResponse(
                text: text,
                model: usedModel ?? model,
                sessionKey: sessionKey,
                tokenCount: (json?["usage"] as? [String: Any])?["total_tokens"] as? Int
            )
        },
        streamAgentMessage: { message, sessionKey, model, channelName in
            AsyncStream { continuation in
                Task {
                    do {
                        let url = URL(string: "http://\(OpenClawConfig.gatewayHost):\(OpenClawConfig.gatewayProxyPort)/v1/chat/completions")!
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.timeoutInterval = 120
                        if let sessionKey { request.setValue(sessionKey, forHTTPHeaderField: "x-clawdbot-session-key") }
                        if let channelName { request.setValue(channelName, forHTTPHeaderField: "x-clawdbot-channel-name") }

                        var body: [String: Any] = [
                            "messages": [["role": "user", "content": message]],
                            "stream": false,
                        ]
                        if let model { body["model"] = model }
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        let (data, response) = try await URLSession.shared.data(for: request)

                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                            let body = String(data: data, encoding: .utf8) ?? ""
                            continuation.yield(GatewayChunk(text: "Gateway error \(statusCode): \(body.prefix(100))", isComplete: true, model: nil))
                            continuation.finish()
                            return
                        }

                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let choices = json?["choices"] as? [[String: Any]]
                        let messageObj = choices?.first?["message"] as? [String: Any]
                        let text = messageObj?["content"] as? String ?? ""
                        let usedModel = json?["model"] as? String
                        continuation.yield(GatewayChunk(text: text, isComplete: true, model: usedModel ?? model))
                    } catch {
                        continuation.yield(GatewayChunk(text: "Error: \(error.localizedDescription)", isComplete: true, model: nil))
                    }
                    continuation.finish()
                }
            }
        },
        checkHealth: {
            do {
                let url = URL(string: "http://\(OpenClawConfig.gatewayHost):\(OpenClawConfig.gatewayProxyPort)/health")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return .connected
                }
                return .disconnected
            } catch {
                return .error(error.localizedDescription)
            }
        },
        sendClawbotMessage: { message, history, sessionKey, channelName, model, voiceDispatch, imageData in
            let url = URL(string: "http://\(OpenClawConfig.gatewayHost):\(OpenClawConfig.gatewayProxyPort)/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.setValue(sessionKey, forHTTPHeaderField: "x-clawdbot-session-key")
            if let channelName { request.setValue(channelName, forHTTPHeaderField: "x-clawdbot-channel-name") }
            if voiceDispatch { request.setValue("true", forHTTPHeaderField: "x-clawdbot-voice-dispatch") }

            let heuristic = model ?? ModelHeuristic.preferredModel(
                for: message,
                category: channelName.flatMap { name in ThreadCategory.allCases.first { $0.channelName == name } },
                explicitChoice: nil
            )
            if let pref = heuristic, model == nil {
                request.setValue(pref, forHTTPHeaderField: "x-clawdbot-model-preference")
            }

            var messages: [[String: Any]] = history.map { msg in
                ["role": msg["role"] ?? "user", "content": msg["content"] ?? ""]
            }
            if let imageData {
                let base64 = imageData.base64EncodedString()
                let content: [[String: Any]] = [
                    ["type": "text", "text": message],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                ]
                messages.append(["role": "user", "content": content])
            }

            var body: [String: Any] = ["messages": messages, "stream": false]
            if let model { body["model"] = model }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw GatewayError.httpError(statusCode, String(data: data, encoding: .utf8) ?? "")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let messageObj = choices?.first?["message"] as? [String: Any]
            return messageObj?["content"] as? String ?? ""
        }
    )
}

public enum GatewayError: Error, LocalizedError {
    case httpError(Int, String)
    case invalidResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case let .httpError(code, body): return "HTTP \(code): \(body.prefix(200))"
        case .invalidResponse: return "Invalid response from gateway"
        case .timeout: return "Gateway request timed out"
        }
    }
}

extension DependencyValues {
    public var gatewayClient: GatewayClient {
        get { self[GatewayClient.self] }
        set { self[GatewayClient.self] = newValue }
    }
}
