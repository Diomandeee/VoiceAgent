import Foundation
import ComposableArchitecture

// MARK: - Gemini Live Client (TCA Dependency)

struct GeminiLiveClient: Sendable {
    /// Connect to Gemini Live WebSocket. silentMode = TEXT-only responses (observer).
    var connect: @Sendable (_ silentMode: Bool) async -> Bool

    /// Disconnect from Gemini Live WebSocket.
    var disconnect: @Sendable () -> Void

    /// Send PCM audio data (Int16 16kHz mono).
    var sendAudio: @Sendable (_ data: Data) -> Void

    /// Send a JPEG video frame.
    var sendVideoFrame: @Sendable (_ jpegData: Data) -> Void

    /// Send a text message.
    var sendText: @Sendable (_ text: String) -> Void

    /// Stream of text responses from Gemini.
    var onTextReceived: @Sendable () -> AsyncStream<String>

    /// Stream of tool calls from Gemini.
    var onToolCall: @Sendable () -> AsyncStream<GeminiToolCall>

    /// Stream of connection state changes.
    var connectionState: @Sendable () -> AsyncStream<GeminiLiveConnectionState>
}

// MARK: - Gemini Config (VoiceAgent variant)

enum GeminiLiveConfig {
    static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let model = "models/gemini-2.0-flash-exp"
    static let inputSampleRate: Double = 16000
    static let videoJPEGQuality: CGFloat = 0.5

    static var apiKey: String {
        UserDefaults.standard.string(forKey: "geminiAPIKey")
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? ""
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    static func websocketURL() -> URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
    }

    static let systemInstruction = """
        You are Claw — a personal AI assistant running on an iOS app. You observe camera feeds and conversations silently. \
        When you notice something relevant or interesting, provide brief context hints. \
        Keep observations to 1-2 sentences. Focus on actionable insights.
        """
}

// MARK: - Gemini Live Engine (MainActor-isolated)

@MainActor
private final class GeminiLiveEngine {
    static let shared = GeminiLiveEngine()

    private(set) var state: GeminiLiveConnectionState = .disconnected
    var silentMode = false

    // Streams
    private var textContinuation: AsyncStream<String>.Continuation?
    private var toolCallContinuation: AsyncStream<GeminiToolCall>.Continuation?
    private var stateContinuation: AsyncStream<GeminiLiveConnectionState>.Continuation?

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private let delegate = GeminiWebSocketDelegate()
    private var urlSession: URLSession!
    private let sendQueue = DispatchQueue(label: "gemini.live.send", qos: .userInitiated)

    // Auto-reconnect
    var autoReconnect = true
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 10
    private var reconnectTask: Task<Void, Never>?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Text Stream

    func makeTextStream() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.textContinuation = continuation
        return stream
    }

    func makeToolCallStream() -> AsyncStream<GeminiToolCall> {
        let (stream, continuation) = AsyncStream<GeminiToolCall>.makeStream()
        self.toolCallContinuation = continuation
        return stream
    }

    func makeStateStream() -> AsyncStream<GeminiLiveConnectionState> {
        let (stream, continuation) = AsyncStream<GeminiLiveConnectionState>.makeStream()
        self.stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    // MARK: - Connect

    func connect(silentMode: Bool) async -> Bool {
        self.silentMode = silentMode

        guard let url = GeminiLiveConfig.websocketURL() else {
            updateState(.error)
            return false
        }

        updateState(.connecting)

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.connectContinuation = continuation

            self.delegate.onOpen = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.updateState(.settingUp)
                    self.sendSetupMessage()
                    self.startReceiving()
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.updateState(.disconnected)
                }
            }

            self.delegate.onError = { [weak self] error in
                guard let self else { return }
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.updateState(.error)
                }
            }

            self.webSocketTask = self.urlSession.webSocketTask(with: url)
            self.webSocketTask?.resume()

            // Timeout after 15 seconds
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    self.resolveConnect(success: false)
                    if self.state == .connecting || self.state == .settingUp {
                        self.updateState(.error)
                    }
                }
            }
        }

        if result {
            reconnectAttempt = 0
        }
        return result
    }

    func disconnect() {
        autoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        delegate.onOpen = nil
        delegate.onClose = nil
        delegate.onError = nil
        textContinuation?.finish()
        toolCallContinuation?.finish()
        updateState(.disconnected)
        resolveConnect(success: false)
    }

    // MARK: - Send

    func sendAudio(_ data: Data) {
        guard state == .ready, let task = webSocketTask else { return }
        let base64 = data.base64EncodedString()
        let json: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64
                ]
            ]
        ]
        sendJSONToTask(json, task: task)
    }

    func sendVideoFrame(_ jpegData: Data) {
        guard state == .ready, let task = webSocketTask else { return }
        let base64 = jpegData.base64EncodedString()
        let json: [String: Any] = [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": base64
                ]
            ]
        ]
        sendJSONToTask(json, task: task)
    }

    func sendText(_ text: String) {
        guard state == .ready, let task = webSocketTask else { return }
        let json: [String: Any] = [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": text]]]
                ],
                "turnComplete": true
            ]
        ]
        sendJSONToTask(json, task: task)
    }

    // MARK: - Private

    private func resolveConnect(success: Bool) {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(returning: success)
        }
    }

    private func updateState(_ newState: GeminiLiveConnectionState) {
        state = newState
        stateContinuation?.yield(newState)
    }

    private func sendSetupMessage() {
        let responseModalities: [String] = silentMode ? ["TEXT"] : ["AUDIO"]

        let setup: [String: Any] = [
            "setup": [
                "model": GeminiLiveConfig.model,
                "generationConfig": [
                    "responseModalities": responseModalities,
                    "thinkingConfig": ["thinkingBudget": 0]
                ],
                "systemInstruction": [
                    "parts": [["text": GeminiLiveConfig.systemInstruction]]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "silenceDurationMs": 500,
                        "prefixPaddingMs": 40
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any]
            ]
        ]

        guard let task = webSocketTask else { return }
        sendJSONToTask(setup, task: task)
    }

    private func sendJSONToTask(_ json: [String: Any], task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else { return }
        sendQueue.async {
            task.send(.string(string)) { _ in }
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.resolveConnect(success: false)
                            self.updateState(.disconnected)
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Setup complete
        if json["setupComplete"] != nil {
            updateState(.ready)
            resolveConnect(success: true)
            return
        }

        // GoAway
        if json["goAway"] != nil {
            updateState(.disconnected)
            return
        }

        // Tool call
        if let toolCallParts = (json["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            let calls = toolCallParts.compactMap { call -> GeminiToolCall.FunctionCall? in
                guard let id = call["id"] as? String,
                      let name = call["name"] as? String else { return nil }
                let args = (call["args"] as? [String: Any])?.compactMapValues { "\($0)" } ?? [:]
                return GeminiToolCall.FunctionCall(id: id, name: name, args: args)
            }
            if !calls.isEmpty {
                toolCallContinuation?.yield(GeminiToolCall(functionCalls: calls))
            }
            return
        }

        // Server content
        if let serverContent = json["serverContent"] as? [String: Any] {
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        textContinuation?.yield(text)
                    }
                }
            }

            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String, !text.isEmpty {
                textContinuation?.yield(text)
            }
        }
    }

    private func attemptReconnect() {
        guard autoReconnect, reconnectAttempt < maxReconnectAttempts else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
        NSLog("[GeminiLive] Reconnecting in %.0fs (attempt %d/%d)", delay, reconnectAttempt, maxReconnectAttempts)

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, autoReconnect else { return }
            let ok = await connect(silentMode: silentMode)
            if ok {
                NSLog("[GeminiLive] Reconnected on attempt %d", reconnectAttempt)
                reconnectAttempt = 0
            }
        }
    }
}

// MARK: - WebSocket Delegate

private final class GeminiWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?(`protocol`)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(closeCode, reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onError?(error) }
    }
}

// MARK: - Live Implementation

extension GeminiLiveClient: DependencyKey {
    static let liveValue = GeminiLiveClient(
        connect: { silentMode in
            await MainActor.run {
                // Return value needs async
            }
            return await GeminiLiveEngine.shared.connect(silentMode: silentMode)
        },
        disconnect: {
            Task { @MainActor in
                GeminiLiveEngine.shared.disconnect()
            }
        },
        sendAudio: { data in
            Task { @MainActor in
                GeminiLiveEngine.shared.sendAudio(data)
            }
        },
        sendVideoFrame: { jpegData in
            Task { @MainActor in
                GeminiLiveEngine.shared.sendVideoFrame(jpegData)
            }
        },
        sendText: { text in
            Task { @MainActor in
                GeminiLiveEngine.shared.sendText(text)
            }
        },
        onTextReceived: {
            // We need a way to bridge the MainActor stream creation
            // Use a continuation to set up the stream from the main actor
            let (stream, continuation) = AsyncStream<String>.makeStream()
            Task { @MainActor in
                let engineStream = GeminiLiveEngine.shared.makeTextStream()
                for await text in engineStream {
                    continuation.yield(text)
                }
                continuation.finish()
            }
            return stream
        },
        onToolCall: {
            let (stream, continuation) = AsyncStream<GeminiToolCall>.makeStream()
            Task { @MainActor in
                let engineStream = GeminiLiveEngine.shared.makeToolCallStream()
                for await call in engineStream {
                    continuation.yield(call)
                }
                continuation.finish()
            }
            return stream
        },
        connectionState: {
            let (stream, continuation) = AsyncStream<GeminiLiveConnectionState>.makeStream()
            Task { @MainActor in
                let engineStream = GeminiLiveEngine.shared.makeStateStream()
                for await state in engineStream {
                    continuation.yield(state)
                }
                continuation.finish()
            }
            return stream
        }
    )
}

extension DependencyValues {
    var geminiLiveClient: GeminiLiveClient {
        get { self[GeminiLiveClient.self] }
        set { self[GeminiLiveClient.self] = newValue }
    }
}
