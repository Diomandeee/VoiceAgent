import ComposableArchitecture
import Foundation
import OpenClawCore


/// Full conversational voice feature — Aura "Direct to Claw" parity in TCA.
/// Manages STT, TTS (ElevenLabs), speaker ID, conversation history,
/// VoiceRouter intent classification, Gemini observer, and visual queries.
@Reducer
struct DirectVoiceFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        // Voice state machine
        var voiceState: VoiceState = .idle
        var interimTranscript: String = ""
        var finalTranscript: String = ""
        var clawResponse: String = ""

        // Session
        var isSessionActive = false
        var activeThreadId: UUID?
        var activeCategory: ThreadCategory = .agent
        var turnCount: Int = 0
        var sessionKey: String = UUID().uuidString

        // TTS
        var ttsEnabled = true
        var ttsMuted = false
        var ttsVerbosity: TTSVerbosity = .concise

        // Model selection
        var selectedModel: AgentModel = .auto

        // Always-on listening
        var isAlwaysOnEnabled = false

        // Speaker ID
        var speakerResult: SpeakerResult = .unknown
        var speakerConfidence: Float = 0
        var speakerGateEnabled = true
        var filteredTranscriptCount = 0

        // Gemini observer
        var geminiObserver = GeminiObserverFeature.State()

        // Visual query
        var visualQueryAvailable = false
        var isCapturingVisualQuery = false

        // Connection
        var gatewayConnected = false

        // Permissions
        var micPermission: PermissionStatus = .unknown
        var speechPermission: PermissionStatus = .unknown
        var cameraPermission: PermissionStatus = .unknown

        // Conversation display
        var conversationHistory: [[String: String]] = []

        // UI
        var showSettings = false
        var showThreadBrowser = false
        var error: String?

        // Activity trace — visible pipeline log
        var activityTrace: [TraceEntry] = []

        struct TraceEntry: Equatable, Sendable, Identifiable {
            let id: UUID
            let timestamp: Date
            let message: String
            let level: TraceLevel

            enum TraceLevel: String, Sendable, Equatable {
                case info, success, error, processing
            }
        }

        mutating func trace(_ message: String, level: TraceEntry.TraceLevel = .info) {
            activityTrace.append(TraceEntry(
                id: UUID(), timestamp: Date(), message: message, level: level
            ))
            // Keep last 20
            if activityTrace.count > 20 {
                activityTrace.removeFirst(activityTrace.count - 20)
            }
        }

        var isListening: Bool {
            voiceState == .listening || voiceState == .backgroundListening
        }

        var isProcessing: Bool {
            voiceState == .processing
        }
    }

    enum Action: Sendable, Equatable {
        // Session lifecycle
        case startSession
        case stopSession
        case resetConversation

        // Speech recognition
        case startListening
        case stopListening
        case speechResult(SpeechResult)
        case interimTranscriptReceived(String)
        case finalTranscriptReceived(String)

        // Intent & routing
        case intentClassified(VoiceRouter.Classified)
        case sendToGateway(String, ThreadCategory?)
        case gatewayResponseReceived(String)
        case gatewayFailed(String)

        // TTS
        case speakResponse(String)
        case ttsSpeechComplete
        case cycleTTSVerbosity
        case toggleMute

        // Model
        case selectModel(AgentModel)

        // Always-on
        case toggleAlwaysOn

        // Speaker ID
        case speakerIdentified(SpeakerResult, Float)
        case enrollSpeaker
        case clearVoiceprint

        // Gemini observer
        case geminiObserver(GeminiObserverFeature.Action)

        // Visual query
        case captureVisualQuery
        case visualQueryCaptured(Data, String)

        // Thread management
        case selectCategory(ThreadCategory)
        case switchThread(UUID)
        case createNewThread(ThreadCategory)
        case threadCreated(HubThread)

        // Gateway
        case checkGateway
        case gatewayStatusChanged(GatewayStatus)

        // Permissions
        case requestPermissions
        case permissionsResult(VoicePermissionStatus)

        // UI
        case toggleSettings
        case toggleThreadBrowser
        case clearError
    }

    @Dependency(\.voiceService) var voiceService
    @Dependency(\.ttsService) var ttsService
    @Dependency(\.speakerIDService) var speakerIDService
    @Dependency(\.conversationHistoryManager) var historyManager
    @Dependency(\.gatewayClient) var gatewayClient
    @Dependency(\.hubClient) var hubClient

    enum CancelID { case listening, alwaysOn, gatewayHealth }

    var body: some ReducerOf<Self> {
        Scope(state: \.geminiObserver, action: \.geminiObserver) {
            GeminiObserverFeature()
        }
        Reduce { state, action in
            switch action {
            // MARK: - Session Lifecycle

            case .startSession:
                state.isSessionActive = true
                state.voiceState = .idle
                state.error = nil
                state.trace("Session started")
                state.trace("Gateway: \(OpenClawConfig.gatewayHost):\(OpenClawConfig.gatewayProxyPort)")
                return .merge(
                    .send(.requestPermissions),
                    .send(.checkGateway)
                )

            case .stopSession:
                state.isSessionActive = false
                state.isAlwaysOnEnabled = false
                state.voiceState = .idle
                state.interimTranscript = ""
                state.finalTranscript = ""
                // Persist conversation to hub_messages if we have a thread
                let history = state.conversationHistory
                let threadId = state.activeThreadId
                return .merge(
                    .cancel(id: CancelID.listening),
                    .cancel(id: CancelID.alwaysOn),
                    .run { _ in
                        await voiceService.stopListening()
                        await ttsService.stop()
                    },
                    // Save final history to thread if present
                    threadId != nil ? .run { _ in
                        // History is already saved per-message, nothing extra needed
                    } : .none
                )

            case .resetConversation:
                state.turnCount = 0
                state.clawResponse = ""
                state.interimTranscript = ""
                state.finalTranscript = ""
                state.conversationHistory = []
                state.sessionKey = UUID().uuidString
                historyManager.clearHistory()
                return .none

            // MARK: - Speech Recognition

            case .startListening:
                state.voiceState = .listening
                state.interimTranscript = ""
                state.finalTranscript = ""
                state.error = nil
                state.trace("Listening...")
                return .run { send in
                    var lastInterim = ""
                    for await result in voiceService.startListening() {
                        if !result.isFinal {
                            lastInterim = result.text
                        } else {
                            lastInterim = ""
                        }
                        await send(.speechResult(result))
                    }
                    // Stream ended — if recognizer was cancelled before emitting isFinal,
                    // promote the last interim transcript so the UI doesn't get stuck
                    if !lastInterim.isEmpty {
                        await send(.speechResult(SpeechResult(text: lastInterim, isFinal: true, confidence: 0.8)))
                    }
                }
                .cancellable(id: CancelID.listening)

            case .stopListening:
                state.voiceState = .idle
                return .merge(
                    .cancel(id: CancelID.listening),
                    .run { _ in
                        await voiceService.stopListening()
                    }
                )

            case let .speechResult(result):
                if result.isFinal {
                    state.finalTranscript = result.text
                    state.interimTranscript = ""
                    guard !result.text.isEmpty else {
                        state.voiceState = state.isAlwaysOnEnabled ? .backgroundListening : .idle
                        return .none
                    }
                    return .send(.finalTranscriptReceived(result.text))
                } else {
                    state.interimTranscript = result.text
                }
                return .none

            case let .interimTranscriptReceived(text):
                state.interimTranscript = text
                return .none

            case let .finalTranscriptReceived(text):
                state.voiceState = .processing
                state.finalTranscript = text
                state.trace("Transcript: \"\(text.prefix(60))\"")

                // Speaker gate: filter unknown speakers in always-on mode
                if state.isAlwaysOnEnabled && state.speakerGateEnabled && state.speakerResult == .unknown {
                    state.filteredTranscriptCount += 1
                    state.voiceState = .backgroundListening
                    NSLog("[DirectVoice] Filtered transcript from unknown speaker")
                    // Resume listening in always-on mode
                    return .send(.startListening)
                }

                // Classify intent via VoiceRouter
                let classified = VoiceRouter.classify(text)
                return .send(.intentClassified(classified))

            // MARK: - Intent & Routing

            case let .intentClassified(classified):
                state.activeCategory = classified.category
                let processed = classified.processed
                let category = classified.category
                state.trace("Intent: \(category.displayName) -> sending", level: .processing)
                return .send(.sendToGateway(processed, category))

            case let .sendToGateway(message, category):
                state.voiceState = .processing
                state.trace("Sending to gateway...", level: .processing)
                let sessionKey = state.sessionKey
                let model: String? = state.selectedModel == .auto
                    ? ModelHeuristic.preferredModel(
                        for: message,
                        category: category,
                        explicitChoice: nil
                    )
                    : state.selectedModel.rawValue
                let channelName = category?.channelName
                let threadId = state.activeThreadId

                // Add to conversation history
                historyManager.appendUserMessage(message)
                state.conversationHistory = historyManager.getHistory()

                return .run { send in
                    do {
                        // Save human message to hub if thread exists
                        if let threadId {
                            _ = try await hubClient.sendMessage(threadId, message, .text, nil, .human, "Mohamed")
                        }

                        // Build full conversation for gateway
                        let history = historyManager.getHistory()

                        let response = try await gatewayClient.sendClawbotMessage(
                            message, history, sessionKey, channelName, model, true, nil
                        )
                        await send(.gatewayResponseReceived(response))
                    } catch {
                        await send(.gatewayFailed(error.localizedDescription))
                    }
                }

            case let .gatewayResponseReceived(response):
                state.voiceState = .responded
                state.clawResponse = response
                state.turnCount += 1
                state.trace("Response: \(response.count) chars", level: .success)

                // Add to history
                historyManager.appendAssistantMessage(response)
                state.conversationHistory = historyManager.getHistory()

                let threadId = state.activeThreadId
                let model = state.selectedModel.displayName

                return .merge(
                    // Speak the response
                    state.ttsEnabled ? .send(.speakResponse(response)) : .none,
                    // Save agent message to hub
                    threadId != nil ? .run { _ in
                        _ = try? await hubClient.sendMessage(threadId!, response, .markdown, nil, .agent, model)
                    } : .none
                )

            case let .gatewayFailed(error):
                state.voiceState = .error
                state.error = error
                state.trace("Gateway failed: \(error.prefix(80))", level: .error)
                // In always-on mode, resume listening after error
                if state.isAlwaysOnEnabled {
                    return .run { send in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await send(.startListening)
                    }
                }
                return .none

            // MARK: - TTS

            case let .speakResponse(text):
                return .run { send in
                    await ttsService.speak(text)
                    await send(.ttsSpeechComplete)
                }

            case .ttsSpeechComplete:
                // In always-on mode, resume listening after TTS finishes
                if state.isAlwaysOnEnabled {
                    state.voiceState = .backgroundListening
                    return .send(.startListening)
                } else {
                    state.voiceState = .responded
                }
                return .none

            case .cycleTTSVerbosity:
                state.ttsVerbosity = state.ttsVerbosity.next()
                return .run { [verbosity = state.ttsVerbosity] _ in
                    await ttsService.setVerbosity(verbosity)
                }

            case .toggleMute:
                state.ttsMuted.toggle()
                return .run { [muted = state.ttsMuted] _ in
                    await ttsService.setMuted(muted)
                }

            // MARK: - Model Selection

            case let .selectModel(model):
                state.selectedModel = model
                return .none

            // MARK: - Always-On

            case .toggleAlwaysOn:
                state.isAlwaysOnEnabled.toggle()
                if state.isAlwaysOnEnabled {
                    state.voiceState = .backgroundListening
                    return .send(.startListening)
                } else {
                    state.voiceState = .idle
                    return .merge(
                        .cancel(id: CancelID.listening),
                        .run { _ in
                            await voiceService.stopListening()
                        }
                    )
                }

            // MARK: - Speaker ID

            case let .speakerIdentified(result, confidence):
                state.speakerResult = result
                state.speakerConfidence = confidence
                return .none

            case .enrollSpeaker:
                // This would typically be triggered from a UI flow
                // where the user speaks enrollment samples
                return .none

            case .clearVoiceprint:
                state.speakerResult = .unknown
                state.speakerConfidence = 0
                return .run { _ in
                    await speakerIDService.clearVoiceprint()
                }

            // MARK: - Gemini Observer (delegated)

            case .geminiObserver:
                return .none

            // MARK: - Visual Query

            case .captureVisualQuery:
                state.isCapturingVisualQuery = true
                // Camera capture would be triggered from the view layer
                return .none

            case let .visualQueryCaptured(jpegData, transcript):
                state.isCapturingVisualQuery = false
                let base64 = jpegData.base64EncodedString()
                let message = "\(transcript)\n\n[Image attached: data:image/jpeg;base64,\(base64.prefix(100))...]"
                let sessionKey = state.sessionKey
                let channelName = state.activeCategory.channelName

                historyManager.appendUserMessage(transcript)
                state.conversationHistory = historyManager.getHistory()
                state.voiceState = .processing

                return .run { send in
                    do {
                        let response = try await gatewayClient.sendClawbotMessage(
                            message, historyManager.getHistory(), sessionKey, channelName, nil, true, jpegData
                        )
                        await send(.gatewayResponseReceived(response))
                    } catch {
                        await send(.gatewayFailed(error.localizedDescription))
                    }
                }

            // MARK: - Thread Management

            case let .selectCategory(category):
                state.activeCategory = category
                return .none

            case let .switchThread(threadId):
                state.activeThreadId = threadId
                // Load thread's history from hub_messages
                return .run { send in
                    let messages = try await hubClient.fetchMessages(threadId, 50, nil)
                    var history: [[String: String]] = []
                    for msg in messages {
                        let role = msg.senderType == .human ? "user" : "assistant"
                        history.append(["role": role, "content": msg.content])
                    }
                    historyManager.setHistory(history)
                    historyManager.trimHistory(10)
                }

            case let .createNewThread(category):
                let sessionKey = state.sessionKey
                return .run { send in
                    let thread = try await hubClient.createThread(
                        .conversation,
                        category.rawValue,
                        "Voice: \(category.displayName)",
                        "Voice conversation",
                        sessionKey,
                        nil
                    )
                    await send(.threadCreated(thread))
                }

            case let .threadCreated(thread):
                state.activeThreadId = thread.id
                state.sessionKey = thread.sessionKey ?? state.sessionKey
                return .none

            // MARK: - Gateway

            case .checkGateway:
                return .run { send in
                    let status = await gatewayClient.checkHealth()
                    await send(.gatewayStatusChanged(status))
                }

            case let .gatewayStatusChanged(status):
                state.gatewayConnected = status == .connected
                switch status {
                case .connected:
                    state.trace("Gateway connected", level: .success)
                case .disconnected:
                    state.trace("Gateway unreachable", level: .error)
                case let .error(msg):
                    state.trace("Gateway error: \(msg.prefix(60))", level: .error)
                }
                return .none

            // MARK: - Permissions

            case .requestPermissions:
                return .run { send in
                    let status = await voiceService.requestPermissions()
                    await send(.permissionsResult(status))
                }

            case let .permissionsResult(status):
                state.micPermission = status.microphone ? .granted : .denied
                state.speechPermission = status.speechRecognition ? .granted : .denied
                state.trace("Mic: \(status.microphone ? "OK" : "denied") | Speech: \(status.speechRecognition ? "OK" : "denied")")
                return .none

            // MARK: - UI

            case .toggleSettings:
                state.showSettings.toggle()
                return .none

            case .toggleThreadBrowser:
                state.showThreadBrowser.toggle()
                return .none

            case .clearError:
                state.error = nil
                state.voiceState = state.isAlwaysOnEnabled ? .backgroundListening : .idle
                return .none
            }
        }
    }
}
