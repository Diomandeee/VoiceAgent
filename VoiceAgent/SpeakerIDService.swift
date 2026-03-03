import Accelerate
import AVFoundation
import CoreML
import Foundation
import ComposableArchitecture

// MARK: - Speaker ID Service (TCA Dependency)

struct SpeakerIDService: Sendable {
    /// Identify speaker from PCM audio data (Int16, 16kHz, mono).
    var identify: @Sendable (_ pcmData: Data) async -> (SpeakerResult, Float)

    /// Enroll owner voiceprint from PCM audio samples.
    var enroll: @Sendable (_ samples: [Data]) async -> Void

    /// Clear the enrolled voiceprint.
    var clearVoiceprint: @Sendable () async -> Void

    /// Check if a voiceprint is enrolled.
    var isEnrolled: @Sendable () async -> Bool
}

// MARK: - Speaker ID Engine (MainActor-isolated)

@MainActor
private final class SpeakerIDEngine {
    static let shared = SpeakerIDEngine()

    private(set) var enrolled = false

    // Configuration
    private let ownerThreshold: Float = 0.70
    private let unknownThreshold: Float = 0.50
    private let minimumDuration: TimeInterval = 1.5
    private let mfccCoefficients = 13

    // CoreML model
    private var coreMLModel: MLModel?
    private var coreMLLoaded = false
    private let modelName = "MohamedSpeakerID"

    // Voiceprint
    private var voiceprintCentroid: [Float]?
    private let voiceprintKey = "speakerVoiceprintCentroid"

    init() {
        loadVoiceprint()
        loadCoreMLModel()
    }

    // MARK: - CoreML Loading

    private func loadCoreMLModel() {
        if let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
                coreMLLoaded = true
                NSLog("[SpeakerID] CoreML model loaded")
            } catch {
                NSLog("[SpeakerID] CoreML model load failed: %@", error.localizedDescription)
            }
        } else if let packageURL = Bundle.main.url(forResource: modelName, withExtension: "mlpackage") {
            Task {
                do {
                    let compiledURL = try await MLModel.compileModel(at: packageURL)
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine
                    let model = try MLModel(contentsOf: compiledURL, configuration: config)
                    self.coreMLModel = model
                    self.coreMLLoaded = true
                    NSLog("[SpeakerID] CoreML model compiled and loaded")
                } catch {
                    NSLog("[SpeakerID] CoreML compile failed: %@ — using MFCC", error.localizedDescription)
                }
            }
        } else {
            NSLog("[SpeakerID] No CoreML model found — using MFCC fallback")
        }
    }

    // MARK: - Identification

    func identify(pcmData: Data) -> (SpeakerResult, Float) {
        let floats = pcmInt16ToFloat(pcmData)
        guard floats.count >= Int(minimumDuration * 16000) else {
            return (.uncertain, 0)
        }

        let features = extractMFCC(from: floats)
        guard !features.isEmpty else {
            return (.uncertain, 0)
        }

        // Try CoreML first
        if coreMLLoaded, let result = identifyWithCoreML(mfccFeatures: features) {
            return result
        }

        // MFCC fallback
        guard let centroid = voiceprintCentroid else {
            return (.uncertain, 0)
        }

        let inputCentroid = computeCentroid(features)
        let similarity = cosineSimilarity(inputCentroid, centroid)

        let result: SpeakerResult
        if similarity >= ownerThreshold {
            result = .owner
        } else if similarity < unknownThreshold {
            result = .unknown
        } else {
            result = .uncertain
        }

        return (result, similarity)
    }

    private func identifyWithCoreML(mfccFeatures: [[Float]]) -> (SpeakerResult, Float)? {
        guard let model = coreMLModel else { return nil }

        let numFrames = mfccFeatures.count
        let numCoeffs = mfccFeatures.first?.count ?? mfccCoefficients

        do {
            let inputArray = try MLMultiArray(
                shape: [1, NSNumber(value: numFrames), NSNumber(value: numCoeffs)],
                dataType: .float32
            )

            for frame in 0..<numFrames {
                for coeff in 0..<numCoeffs {
                    let index = frame * numCoeffs + coeff
                    inputArray[index] = NSNumber(value: mfccFeatures[frame][coeff])
                }
            }

            let input = try MLDictionaryFeatureProvider(dictionary: ["audio_features": inputArray])
            let prediction = try model.prediction(from: input)

            if let confidence = prediction.featureValue(for: "confidence")?.doubleValue {
                let conf = Float(confidence)
                let label = prediction.featureValue(for: "speaker_label")?.stringValue ?? ""

                let result: SpeakerResult
                if label == "owner" && conf >= ownerThreshold {
                    result = .owner
                } else if conf < unknownThreshold {
                    result = .unknown
                } else {
                    result = .uncertain
                }
                return (result, conf)
            }
        } catch {
            NSLog("[SpeakerID] CoreML prediction failed: %@", error.localizedDescription)
        }

        return nil
    }

    // MARK: - Enrollment

    func enrollFromPCM(_ samples: [Data]) {
        guard !samples.isEmpty else { return }

        var allFeatures: [[Float]] = []
        for sample in samples {
            let floats = pcmInt16ToFloat(sample)
            guard floats.count >= 4000 else { continue }
            let features = extractMFCC(from: floats)
            allFeatures.append(contentsOf: features)
        }

        guard !allFeatures.isEmpty else {
            NSLog("[SpeakerID] Enrollment failed — no valid features")
            return
        }

        voiceprintCentroid = computeCentroid(allFeatures)
        enrolled = true
        saveVoiceprint()
        NSLog("[SpeakerID] Enrolled with %d features from %d samples", allFeatures.count, samples.count)
    }

    func clearVoiceprint() {
        voiceprintCentroid = nil
        enrolled = false
        UserDefaults.standard.removeObject(forKey: voiceprintKey)
        NSLog("[SpeakerID] Voiceprint cleared")
    }

    // MARK: - MFCC Extraction

    private func extractMFCC(from samples: [Float]) -> [[Float]] {
        let frameSize = 512
        let hopSize = 256
        var features: [[Float]] = []

        var frameStart = 0
        while frameStart + frameSize <= samples.count {
            let frame = Array(samples[frameStart..<(frameStart + frameSize)])
            var windowed = applyHammingWindow(frame)
            let powerSpectrum = computePowerSpectrum(&windowed)
            let melEnergies = applyMelFilterbank(powerSpectrum, numFilters: 26)
            let logMelEnergies = melEnergies.map { log(max($0, 1e-10)) }
            let mfcc = dct(logMelEnergies, numCoeffs: mfccCoefficients)
            features.append(mfcc)
            frameStart += hopSize
        }

        return features
    }

    private func applyHammingWindow(_ frame: [Float]) -> [Float] {
        let n = frame.count
        return frame.enumerated().map { i, sample in
            let window = 0.54 - 0.46 * cos(2.0 * Float.pi * Float(i) / Float(n - 1))
            return sample * window
        }
    }

    private func computePowerSpectrum(_ frame: inout [Float]) -> [Float] {
        let n = frame.count
        let halfN = n / 2

        let log2n = vDSP_Length(log2(Float(n)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: halfN)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        frame.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
            }
        }

        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

        var magnitudes = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

        var scale: Float = 1.0 / Float(n * n)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

        return magnitudes
    }

    private func applyMelFilterbank(_ spectrum: [Float], numFilters: Int) -> [Float] {
        let sampleRate: Float = 16000
        let fftSize = spectrum.count * 2
        let numBins = spectrum.count

        func hzToMel(_ hz: Float) -> Float { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Float) -> Float { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let lowMel = hzToMel(300)
        let highMel = hzToMel(sampleRate / 2)

        var melPoints = [Float](repeating: 0, count: numFilters + 2)
        for i in 0..<(numFilters + 2) {
            melPoints[i] = lowMel + Float(i) * (highMel - lowMel) / Float(numFilters + 1)
        }

        let binPoints = melPoints.map { mel -> Int in
            let hz = melToHz(mel)
            return Int(hz * Float(fftSize) / sampleRate)
        }

        var filterEnergies = [Float](repeating: 0, count: numFilters)

        for i in 0..<numFilters {
            let startBin = binPoints[i]
            let centerBin = binPoints[i + 1]
            let endBin = binPoints[i + 2]

            for j in startBin..<min(centerBin, numBins) {
                let weight = Float(j - startBin) / max(Float(centerBin - startBin), 1)
                filterEnergies[i] += spectrum[min(j, numBins - 1)] * weight
            }
            for j in centerBin..<min(endBin, numBins) {
                let weight = Float(endBin - j) / max(Float(endBin - centerBin), 1)
                filterEnergies[i] += spectrum[min(j, numBins - 1)] * weight
            }
        }

        return filterEnergies
    }

    private func dct(_ input: [Float], numCoeffs: Int) -> [Float] {
        let n = input.count
        var output = [Float](repeating: 0, count: numCoeffs)
        for k in 0..<numCoeffs {
            var sum: Float = 0
            for i in 0..<n {
                sum += input[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            output[k] = sum
        }
        return output
    }

    // MARK: - Vector Operations

    private func computeCentroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dim = first.count
        var centroid = [Float](repeating: 0, count: dim)

        for vector in vectors {
            for i in 0..<min(dim, vector.count) {
                centroid[i] += vector[i]
            }
        }

        let count = Float(vectors.count)
        for i in 0..<dim {
            centroid[i] /= count
        }
        return centroid
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dotProduct / denominator
    }

    // MARK: - Audio Conversion

    private func pcmInt16ToFloat(_ data: Data) -> [Float] {
        let int16Count = data.count / 2
        guard int16Count > 0 else { return [] }

        return data.withUnsafeBytes { rawBuffer -> [Float] in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return [] }
            var floats = [Float](repeating: 0, count: int16Count)
            for i in 0..<int16Count {
                floats[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
            return floats
        }
    }

    // MARK: - Persistence

    private func saveVoiceprint() {
        guard let centroid = voiceprintCentroid else { return }
        let data = centroid.withUnsafeBufferPointer { Data(buffer: $0) }
        UserDefaults.standard.set(data, forKey: voiceprintKey)
    }

    private func loadVoiceprint() {
        guard let data = UserDefaults.standard.data(forKey: voiceprintKey) else { return }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return }

        voiceprintCentroid = data.withUnsafeBytes { rawBuffer -> [Float] in
            guard let ptr = rawBuffer.bindMemory(to: Float.self).baseAddress else { return [] }
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        enrolled = true
        NSLog("[SpeakerID] Voiceprint loaded (%d dimensions)", count)
    }
}

// MARK: - Live Implementation

extension SpeakerIDService: DependencyKey {
    static let liveValue = SpeakerIDService(
        identify: { pcmData in
            await MainActor.run {
                SpeakerIDEngine.shared.identify(pcmData: pcmData)
            }
        },
        enroll: { samples in
            await MainActor.run {
                SpeakerIDEngine.shared.enrollFromPCM(samples)
            }
        },
        clearVoiceprint: {
            await MainActor.run {
                SpeakerIDEngine.shared.clearVoiceprint()
            }
        },
        isEnrolled: {
            await MainActor.run {
                SpeakerIDEngine.shared.enrolled
            }
        }
    )
}

extension DependencyValues {
    var speakerIDService: SpeakerIDService {
        get { self[SpeakerIDService.self] }
        set { self[SpeakerIDService.self] = newValue }
    }
}
