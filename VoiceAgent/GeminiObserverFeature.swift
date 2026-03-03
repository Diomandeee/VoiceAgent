import ComposableArchitecture
import Foundation

/// TCA reducer managing Gemini as a silent observer alongside Clawbot conversations.
/// Connects in silent mode (text-only responses), receives camera frames,
/// and surfaces insights as context hints for the main conversation.
@Reducer
struct GeminiObserverFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var isEnabled = false
        var connectionState: GeminiLiveConnectionState = .disconnected
        var latestInsight: String?
        var insightTimestamp: Date?
        var reconnectAttempt = 0
        var insightCount = 0
    }

    enum Action: Sendable, Equatable {
        case toggle
        case connect
        case disconnect
        case connectionStateChanged(GeminiLiveConnectionState)
        case insightReceived(String)
        case clearInsight
        case sendVideoFrame(Data)
        case sendAudioChunk(Data)
    }

    @Dependency(\.geminiLiveClient) var geminiLiveClient
    @Dependency(\.conversationHistoryManager) var historyManager

    enum CancelID { case observerStream, stateStream }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .toggle:
                state.isEnabled.toggle()
                if state.isEnabled {
                    return .send(.connect)
                } else {
                    return .send(.disconnect)
                }

            case .connect:
                guard state.isEnabled else { return .none }
                return .merge(
                    // Connect in silent mode
                    .run { send in
                        let connected = await geminiLiveClient.connect(true)
                        if !connected {
                            await send(.connectionStateChanged(.error))
                        }
                    },
                    // Listen for text responses (insights)
                    .run { send in
                        for await text in geminiLiveClient.onTextReceived() {
                            await send(.insightReceived(text))
                        }
                    }
                    .cancellable(id: CancelID.observerStream),
                    // Listen for connection state changes
                    .run { send in
                        for await connectionState in geminiLiveClient.connectionState() {
                            await send(.connectionStateChanged(connectionState))
                        }
                    }
                    .cancellable(id: CancelID.stateStream)
                )

            case .disconnect:
                state.isEnabled = false
                state.connectionState = .disconnected
                state.latestInsight = nil
                geminiLiveClient.disconnect()
                return .merge(
                    .cancel(id: CancelID.observerStream),
                    .cancel(id: CancelID.stateStream)
                )

            case let .connectionStateChanged(newState):
                state.connectionState = newState
                return .none

            case let .insightReceived(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                state.latestInsight = trimmed
                state.insightTimestamp = Date()
                state.insightCount += 1
                // Inject as context hint for the next Clawbot message
                historyManager.setContextHint(trimmed)
                return .none

            case .clearInsight:
                state.latestInsight = nil
                state.insightTimestamp = nil
                return .none

            case let .sendVideoFrame(jpegData):
                guard state.connectionState == .ready else { return .none }
                geminiLiveClient.sendVideoFrame(jpegData)
                return .none

            case let .sendAudioChunk(pcmData):
                guard state.connectionState == .ready else { return .none }
                geminiLiveClient.sendAudio(pcmData)
                return .none
            }
        }
    }
}
