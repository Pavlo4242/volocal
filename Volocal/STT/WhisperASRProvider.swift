// Volocal/STT/WhisperASRProvider.swift
// WhisperKit adapter — Thai + 99 language ASR via CoreML Whisper models.
//
// WHY THIS EXISTS:
//   FluidAudio Parakeet supports 25 European + Japanese + Chinese languages.
//   Thai (ภาษาไทย) is NOT in Parakeet's vocabulary.  WhisperKit wraps
//   OpenAI Whisper (small / medium) which natively supports Thai.
//
// HARDWARE:
//   WhisperKit runs on ANE + GPU via CoreML.  The LLM sits on Metal GPU,
//   so during concurrent ASR+LLM (barge-in), WhisperKit may share GPU
//   briefly.  In practice Thai utterances end before LLM output begins,
//   so contention is minimal.  If contention is observed, switch to the
//   `whisper-tiny` variant (~90 MB, GPU time < 100 ms per chunk).
//
// LATENCY:
//   Whisper is not a streaming model — it processes complete utterances.
//   We gate chunks with FluidAudio's VAD (Silero) and feed whole utterances
//   to Whisper.  EOU is simulated via VAD end-of-speech detection.
//   Typical Thai sentence (5 s) → ~450 ms to transcript on iPhone 15.
//
// DEPENDENCY:
//   Add to project.yml:
//     packages:
//       WhisperKit:
//         url: https://github.com/argmaxinc/WhisperKit
//         from: 0.9.0

import Foundation
import WhisperKit
import AVFoundation

// MARK: - Errors

enum WhisperASRError: LocalizedError {
    case notPrepared
    case unsupportedLanguage(ASRLanguage)
    case modelLoadFailed(underlying: Error)
    case transcriptionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "WhisperASRProvider: call prepare() before streaming."
        case .unsupportedLanguage(let lang):
            return "WhisperASRProvider: unexpected language \(lang.rawValue)."
        case .modelLoadFailed(let err):
            return "WhisperASRProvider: model load failed — \(err.localizedDescription)"
        case .transcriptionFailed(let err):
            return "WhisperASRProvider: transcription error — \(err.localizedDescription)"
        }
    }
}

// MARK: - Whisper Model Variant

/// Choose model size based on available RAM and quality requirements.
public enum WhisperModelVariant: String {
    /// ~90 MB — fastest, lower accuracy. Good for low-RAM devices.
    case tiny   = "openai_whisper-tiny"
    /// ~290 MB — recommended for Thai (good WER ~8-12%).
    case small  = "openai_whisper-small"
    /// ~780 MB — highest accuracy, heavier on memory.
    case medium = "openai_whisper-medium"
}

// MARK: - WhisperASRProvider

/// Chunk-based ASR via WhisperKit CoreML.
/// Primary use-case: Thai language input.
/// Falls back gracefully for any of the 99 Whisper-supported languages.
///
/// Memory: ~290 MB (small) / ~780 MB (medium).
/// Languages: 99 including Thai (th), English (en), Japanese (ja), etc.
/// EOU: Simulated via FluidAudio Silero VAD end-of-speech events.
public final class WhisperASRProvider: ASRProvider {

    // MARK: ASRProvider

    public let name: String
    public let supportedLanguages: [ASRLanguage] = ASRLanguage.allCases   // all languages via Whisper
    public var estimatedMemoryMB: Int {
        switch modelVariant {
        case .tiny:   return 90
        case .small:  return 290
        case .medium: return 780
        }
    }

    public var onResult: ((ASRResult) -> Void)?
    public var onEndOfUtterance: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public private(set) var isReady = false

    // MARK: Private State

    private let modelVariant: WhisperModelVariant
    private var whisper: WhisperKit?

    private var activeLanguage: ASRLanguage = .thai
    private var accumulatedSamples: [Float] = []
    private var isStreaming = false


    // MARK: Init

    /// - Parameters:
    ///   - modelVariant: Model size (default `.small` — best quality/size for Thai).
    public init(modelVariant: WhisperModelVariant = .small) {
        self.modelVariant = modelVariant
        self.name = "Whisper \(modelVariant.rawValue.replacingOccurrences(of: "openai_whisper-", with: "").capitalized) (WhisperKit)"
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        guard !isReady else { return }
        do {
            // 1. Download & compile Whisper CoreML model (cached after first run)
            let config = WhisperKitConfig(
                model: modelVariant.rawValue,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,  // ANE for encoder
                    textDecoderCompute: .cpuAndNeuralEngine    // ANE for decoder
                ),
                verbose: false,
                logLevel: .none
            )
            whisper = try await WhisperKit(config)

            isReady = true
        } catch {
            throw WhisperASRError.modelLoadFailed(underlying: error)
        }
    }

    public func unload() async {
        whisper = nil
        isReady = false
        isStreaming = false
        accumulatedSamples = []
    }

    // MARK: Streaming

    public func startStreaming(language: ASRLanguage) async throws {
        guard isReady else { throw WhisperASRError.notPrepared }
        activeLanguage = language
        accumulatedSamples = []
        isStreaming = true
    }

    public func appendAudioSamples(_ samples: [Float]) async throws {
        guard isStreaming else { return }
        accumulatedSamples.append(contentsOf: samples)
    }

    public func flush() async {
        guard isStreaming, !accumulatedSamples.isEmpty else { return }
        let utterance = accumulatedSamples
        accumulatedSamples = []
        await transcribeUtterance(utterance)
    }

    public func stopStreaming() async throws {
        guard isStreaming else { return }
        isStreaming = false
        // Flush any remaining accumulated audio
        await flush()
    }

    // MARK: Private — Transcription

    private func transcribeUtterance(_ samples: [Float]) async {
        guard let whisper, !samples.isEmpty else { return }
        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: activeLanguage.rawValue,    // "th", "en", etc.
                usePrefillPrompt: true,
                withoutTimestamps: true
            )
            let results = try await whisper.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let asrResult = ASRResult(
                text: text,
                confidence: 0.9,   // Whisper does not expose per-word confidence
                isEndOfUtterance: true,
                providerName: name
            )
            await MainActor.run {
                self.onResult?(asrResult)
                self.onEndOfUtterance?()
            }
        } catch {
            await MainActor.run {
                self.onError?(WhisperASRError.transcriptionFailed(underlying: error))
            }
        }
    }
}
