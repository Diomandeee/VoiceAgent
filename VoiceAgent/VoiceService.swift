import AVFoundation
import Speech
import ComposableArchitecture

// MARK: - Voice Service (STT + TTS)

struct VoiceService: Sendable {
    /// Request microphone + speech recognition permissions
    var requestPermissions: @Sendable () async -> VoicePermissionStatus

    /// Start on-device speech recognition, returns transcript chunks
    var startListening: @Sendable () -> AsyncStream<SpeechResult>

    /// Stop listening
    var stopListening: @Sendable () async -> Void

    /// Speak text aloud using system TTS
    var speak: @Sendable (_ text: String, _ rate: Float) async -> Void

    /// Stop speaking
    var stopSpeaking: @Sendable () async -> Void
}

// MARK: - Types

struct VoicePermissionStatus: Equatable, Sendable {
    var microphone: Bool
    var speechRecognition: Bool
    var isFullyGranted: Bool { microphone && speechRecognition }
}

struct SpeechResult: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Float
}

// MARK: - Speech Engine (MainActor-isolated for AVFoundation compatibility)

@MainActor
private final class SpeechEngine {
    static let shared = SpeechEngine()

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceWorkItem: DispatchWorkItem?
    private var continuation: AsyncStream<SpeechResult>.Continuation?
    private var lastTranscript: String?

    func start(continuation: AsyncStream<SpeechResult>.Continuation) {
        stopInternal()
        self.continuation = continuation

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            self.continuation?.finish()
            self.continuation = nil
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        self.audioEngine = engine
        self.recognitionRequest = request

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // append() is documented as safe to call from the audio tap thread
            nonisolated(unsafe) let audioRequest = request
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                audioRequest.append(buffer)
            }

            engine.prepare()
            try engine.start()
        } catch {
            self.continuation?.yield(SpeechResult(text: "Audio error: \(error.localizedDescription)", isFinal: true, confidence: 0))
            self.continuation?.finish()
            self.continuation = nil
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Extract Sendable values before crossing isolation boundary
            let transcript: (text: String, confidence: Float, isFinal: Bool)?
            if let result {
                transcript = (
                    result.bestTranscription.formattedString,
                    Float(result.bestTranscription.segments.last?.confidence ?? 0),
                    result.isFinal
                )
            } else {
                transcript = nil
            }
            let errorInfo: (domain: String, code: Int)?
            if let error {
                let ns = error as NSError
                errorInfo = (ns.domain, ns.code)
            } else {
                errorInfo = nil
            }
            Task { @MainActor [weak self] in
                self?.handleResult(transcript: transcript, errorInfo: errorInfo)
            }
        }
    }

    private func handleResult(
        transcript: (text: String, confidence: Float, isFinal: Bool)?,
        errorInfo: (domain: String, code: Int)?
    ) {
        guard let transcript else {
            if let errorInfo {
                // Codes 209/216 are transient — don't treat as fatal
                if errorInfo.domain == "kAFAssistantErrorDomain" && (errorInfo.code == 209 || errorInfo.code == 216) {
                    return
                }
            }
            continuation?.finish()
            continuation = nil
            return
        }

        continuation?.yield(SpeechResult(
            text: transcript.text,
            isFinal: transcript.isFinal,
            confidence: transcript.confidence
        ))

        if !transcript.isFinal {
            lastTranscript = transcript.text
        }

        resetSilenceTimer()

        if transcript.isFinal {
            lastTranscript = nil
            continuation?.finish()
            continuation = nil
        }
    }

    private func resetSilenceTimer() {
        silenceWorkItem?.cancel()

        // Adaptive timeout: shorter for complete sentences, longer for mid-thought
        let currentText = lastTranscript ?? ""
        let endsWithPunctuation = currentText.hasSuffix(".") || currentText.hasSuffix("?") || currentText.hasSuffix("!")
        let timeout: TimeInterval = endsWithPunctuation ? 1.2 : 2.5

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endListeningGracefully()
            }
        }
        silenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    /// End listening gracefully — signals end of audio without cancelling the recognizer,
    /// allowing it to emit isFinal = true for the remaining buffer.
    func endListeningGracefully() {
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        // Signal end of audio — recognizer will process remaining buffer and emit isFinal
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        // Do NOT cancel recognitionTask — let it finish naturally
    }

    /// Hard stop — used for explicit user-initiated cancellation.
    func stopInternal() {
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        lastTranscript = nil
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - TTS Engine (MainActor-isolated)

@MainActor
private final class TTSEngine {
    static let shared = TTSEngine()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, rate: Float) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(rate, AVSpeechUtteranceMaximumSpeechRate))
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - Permission Helpers (isolated to avoid sending issues)

@Sendable
private func requestMicPermission() async -> Bool {
    await withCheckedContinuation { cont in
        AVAudioApplication.requestRecordPermission { granted in
            cont.resume(returning: granted)
        }
    }
}

@Sendable
private func requestSpeechPermission() async -> Bool {
    await withCheckedContinuation { cont in
        SFSpeechRecognizer.requestAuthorization { status in
            cont.resume(returning: status == .authorized)
        }
    }
}

// MARK: - Live Implementation

extension VoiceService: DependencyKey {
    static let liveValue = VoiceService(
        requestPermissions: {
            let mic = await requestMicPermission()
            let speech = await requestSpeechPermission()
            return VoicePermissionStatus(microphone: mic, speechRecognition: speech)
        },
        startListening: {
            let (stream, continuation) = AsyncStream<SpeechResult>.makeStream()
            Task { @MainActor in
                SpeechEngine.shared.start(continuation: continuation)
            }
            return stream
        },
        stopListening: {
            await MainActor.run {
                SpeechEngine.shared.stopInternal()
            }
        },
        speak: { text, rate in
            await MainActor.run {
                TTSEngine.shared.speak(text: text, rate: rate)
            }
        },
        stopSpeaking: {
            await MainActor.run {
                TTSEngine.shared.stop()
            }
        }
    )
}

extension DependencyValues {
    var voiceService: VoiceService {
        get { self[VoiceService.self] }
        set { self[VoiceService.self] = newValue }
    }
}
