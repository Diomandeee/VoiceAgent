import AVFoundation
import Foundation
import ComposableArchitecture

// MARK: - TTS Service (TCA Dependency)

struct TTSService: Sendable {
    /// Speak text using ElevenLabs (primary) or system TTS (fallback).
    var speak: @Sendable (_ text: String) async -> Void

    /// Stop current speech.
    var stop: @Sendable () async -> Void

    /// Set muted state (skips audio output entirely).
    var setMuted: @Sendable (_ muted: Bool) async -> Void

    /// Set verbosity mode (controls response truncation before speaking).
    var setVerbosity: @Sendable (_ verbosity: TTSVerbosity) async -> Void

    /// Check if currently speaking.
    var isSpeaking: @Sendable () async -> Bool
}

// MARK: - ElevenLabs TTS Engine (MainActor-isolated)

@MainActor
private final class ElevenLabsTTSEngine {
    static let shared = ElevenLabsTTSEngine()

    private(set) var isSpeaking = false
    private(set) var currentProvider: TTSProvider = .elevenLabs

    var isMuted = false
    var verbosity: TTSVerbosity = .concise

    // ElevenLabs config
    private let voiceId = "TmSgyk1vGAD9YzdtJV3V"
    private let modelId = "eleven_turbo_v2_5"
    private let stability: Float = 0.5
    private let similarityBoost: Float = 0.75
    private let speed: Float = 1.5

    private let session: URLSession
    private var currentTask: URLSessionDataTask?
    private let systemSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isMuted {
            NSLog("[TTS] Muted — skipping audio for %d chars", trimmed.count)
            return
        }

        // Apply verbosity truncation
        let truncated = applyVerbosity(trimmed)

        isSpeaking = true
        NSLog("[TTS] Speaking %d chars via %@", truncated.count, currentProvider.rawValue)

        let success = await speakWithElevenLabs(truncated)
        if !success {
            NSLog("[TTS] ElevenLabs failed, falling back to system TTS")
            currentProvider = .system
            await speakWithSystem(truncated)
            return
        }

        isSpeaking = false
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        systemSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func applyVerbosity(_ text: String) -> String {
        let maxSentences = verbosity.maxSentences
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count <= maxSentences {
            return text
        }

        return sentences.prefix(maxSentences).joined(separator: ". ") + "."
    }

    // MARK: - ElevenLabs Streaming TTS

    private func speakWithElevenLabs(_ text: String) async -> Bool {
        let apiKey = elevenLabsAPIKey
        guard !apiKey.isEmpty else {
            NSLog("[TTS] No ElevenLabs API key configured")
            return false
        }

        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream"
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": stability,
                "similarity_boost": similarityBoost,
                "style": Float(0.0),
                "use_speaker_boost": true
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("[TTS] ElevenLabs HTTP %d", statusCode)
                return false
            }

            guard !data.isEmpty else { return false }

            // Convert MP3 -> PCM and play
            if let pcmData = await convertMP3ToPCM(data) {
                await playPCMData(pcmData)
                currentProvider = .elevenLabs
                NSLog("[TTS] ElevenLabs delivered %d bytes PCM", pcmData.count)
                return true
            }

            return false
        } catch {
            NSLog("[TTS] ElevenLabs error: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - MP3 -> PCM Conversion

    private func convertMP3ToPCM(_ mp3Data: Data) async -> Data? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(UUID().uuidString).mp3")
        do {
            try mp3Data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let audioFile = try AVAudioFile(forReading: tempURL)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24000,
                channels: 1,
                interleaved: true
            )!

            let frameCount = UInt32(audioFile.length)
            guard frameCount > 0,
                  let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: frameCount
                  ) else { return nil }

            try audioFile.read(into: readBuffer)

            guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: format),
                  let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: UInt32(Double(frameCount) * (24000.0 / audioFile.processingFormat.sampleRate))
                  ) else { return nil }

            var error: NSError?
            var consumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return readBuffer
            }

            guard error == nil, outputBuffer.frameLength > 0 else { return nil }

            let byteCount = Int(outputBuffer.frameLength) * 2
            let audioData = Data(
                bytes: outputBuffer.int16ChannelData![0],
                count: byteCount
            )
            return audioData
        } catch {
            NSLog("[TTS] MP3->PCM conversion failed: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - PCM Playback

    private func playPCMData(_ pcmData: Data) async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_play_\(UUID().uuidString).wav")

        // Write WAV header + PCM data
        let sampleRate: UInt32 = 24000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(pcmData.count)
        let headerSize: UInt32 = 44

        var wavData = Data()
        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(littleEndian: dataSize + headerSize - 8)
        wavData.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(littleEndian: UInt32(16)) // chunk size
        wavData.append(littleEndian: UInt16(1))  // PCM format
        wavData.append(littleEndian: channels)
        wavData.append(littleEndian: sampleRate)
        wavData.append(littleEndian: sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8))
        wavData.append(littleEndian: UInt16(channels) * (bitsPerSample / 8))
        wavData.append(littleEndian: bitsPerSample)
        // data chunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(littleEndian: dataSize)
        wavData.append(pcmData)

        do {
            try wavData.write(to: tempURL)
            let player = try AVAudioPlayer(contentsOf: tempURL)
            player.enableRate = true
            player.rate = speed
            self.audioPlayer = player
            player.play()

            // Wait for playback to finish
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            NSLog("[TTS] Playback error: %@", error.localizedDescription)
        }
    }

    // MARK: - System TTS Fallback

    private func speakWithSystem(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.5
        utterance.pitchMultiplier = 1.0
        systemSynthesizer.speak(utterance)
        currentProvider = .system

        while systemSynthesizer.isSpeaking {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        isSpeaking = false
    }

    // MARK: - API Key

    private var elevenLabsAPIKey: String {
        UserDefaults.standard.string(forKey: "elevenLabsAPIKey")
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
            ?? ""
    }
}

// MARK: - Data Extension for WAV Writing

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}

// MARK: - Live Implementation

extension TTSService: DependencyKey {
    static let liveValue = TTSService(
        speak: { text in
            await ElevenLabsTTSEngine.shared.speak(text)
        },
        stop: {
            await MainActor.run {
                ElevenLabsTTSEngine.shared.stop()
            }
        },
        setMuted: { muted in
            await MainActor.run {
                ElevenLabsTTSEngine.shared.isMuted = muted
            }
        },
        setVerbosity: { verbosity in
            await MainActor.run {
                ElevenLabsTTSEngine.shared.verbosity = verbosity
            }
        },
        isSpeaking: {
            await MainActor.run {
                ElevenLabsTTSEngine.shared.isSpeaking
            }
        }
    )
}

extension DependencyValues {
    var ttsService: TTSService {
        get { self[TTSService.self] }
        set { self[TTSService.self] = newValue }
    }
}
