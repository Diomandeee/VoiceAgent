import Foundation

// MARK: - Voice State Machine

enum VoiceState: String, Equatable, Sendable {
    case idle
    case listening
    case processing
    case responded
    case error
    case backgroundListening
}

// MARK: - TTS Verbosity

enum TTSVerbosity: String, CaseIterable, Equatable, Sendable {
    case concise
    case detailed
    case full

    var displayName: String {
        switch self {
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .full: return "Full"
        }
    }

    var icon: String {
        switch self {
        case .concise: return "text.badge.minus"
        case .detailed: return "text.badge.plus"
        case .full: return "doc.text"
        }
    }

    var maxSentences: Int {
        switch self {
        case .concise: return 2
        case .detailed: return 5
        case .full: return 20
        }
    }

    func next() -> TTSVerbosity {
        switch self {
        case .concise: return .detailed
        case .detailed: return .full
        case .full: return .concise
        }
    }
}

// MARK: - Speaker Identification

enum SpeakerResult: String, Equatable, Sendable {
    case owner
    case unknown
    case uncertain

    var label: String {
        switch self {
        case .owner: return "Mo"
        case .unknown: return "?"
        case .uncertain: return "~"
        }
    }

    var icon: String {
        switch self {
        case .owner: return "person.fill.checkmark"
        case .unknown: return "person.fill.questionmark"
        case .uncertain: return "person.fill.xmark"
        }
    }
}

// MARK: - Gemini Connection State

enum GeminiLiveConnectionState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case settingUp
    case ready
    case error

    var isConnected: Bool { self == .ready }

    var statusColor: String {
        switch self {
        case .disconnected: return "gray"
        case .connecting, .settingUp: return "orange"
        case .ready: return "green"
        case .error: return "red"
        }
    }
}

// MARK: - Agent Model (reuse from AgentChatFeature)

enum AgentModel: String, CaseIterable, Sendable, Equatable {
    case auto
    case claude
    case gemini

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkle"
        case .claude: return "brain.head.profile"
        case .gemini: return "diamond"
        }
    }
}

// MARK: - Permission Status

enum PermissionStatus: String, Equatable, Sendable {
    case unknown
    case granted
    case denied
    case restricted
}

// MARK: - Gemini Tool Call

struct GeminiToolCall: Equatable, Sendable {
    struct FunctionCall: Equatable, Sendable {
        let id: String
        let name: String
        let args: [String: String]
    }
    let functionCalls: [FunctionCall]
}

// MARK: - TTS Provider

enum TTSProvider: String, Equatable, Sendable {
    case elevenLabs = "ElevenLabs"
    case system = "System"
}
