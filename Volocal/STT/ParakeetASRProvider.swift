// Volocal/STT/ParakeetASRProvider.swift
// FluidAudio Parakeet EOU adapter — streaming ASR on the Apple Neural Engine.
// Replaces the original STTManager.  English only; lowest latency; built-in EOU.

import Foundation
import FluidAudio
import AVFoundation

// MARK: - Errors

enum ParakeetASRError: LocalizedError {
    case notPrepared
    case modelLoadFailed(underlying: Error)
    case streamingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "ParakeetASRProvider: call prepare() before streaming."
        case .modelLoadFailed(let err):
            return "ParakeetASRProvider: model load failed — \(err.localizedDescription)"
        case .streamingFailed(let err):
            return "ParakeetASRProvider: streaming error — \(err.localizedDescription)"
        }
    }
}

// MARK: - ParakeetASRProvider

/// Wraps FluidAudio's `SlidingWindowAsrManager` (Parakeet EOU 120M).
/// Runs entirely on the Apple Neural Engine — leaves GPU free for the LLM.
///
/// Memory: ~200 MB peak.
/// Languages: English only.
/// EOU: Built-in end-of-utterance detection (no separate VAD needed).
public final class ParakeetASRProvider: ASRProvider {

    // MARK: ASRProvider

    public let name = "Qwen3 ASR (FluidAudio)"
    public let supportedLanguages: [ASRLanguage] = [.english]
    public var estimatedMemoryMB: Int { 200 }

    public var onResult: ((ASRResult) -> Void)?
    public var onEndOfUtterance: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public private(set) var isReady = false

    // MARK: Private State

    // FluidAudio managers — initialised in prepare()
    private var asrManager: SlidingWindowAsrManager?
    private var asrModels: AsrModels?

    // Chunk-size setting (160 ms = lowest latency, 320 ms = balanced)
    private let chunkSizeMs: Int

    // Accumulates partial text between EOU events
    private var partialBuffer = ""
    private var isStreaming = false
    private var updatesTask: Task<Void, Never>?

    // A cached format for AVAudioPCMBuffer creation
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // MARK: Init

    /// - Parameter chunkSizeMs: 160 (default, lowest latency), 320, or 1600.
    public init(chunkSizeMs: Int = 160) {
        self.chunkSizeMs = chunkSizeMs
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        guard !isReady else { return }
        do {
            let modelsDir = await STTManager.modelsDirectory()
            let modelDir = modelsDir.appendingPathComponent(Repo.parakeetEou320.folderName)

            let encoderPath = modelDir.appendingPathComponent("streaming_encoder.mlmodelc")
            if !FileManager.default.fileExists(atPath: encoderPath.path) {
                try await DownloadUtils.downloadRepo(.parakeetEou320, to: modelsDir)
            }

            let config = SlidingWindowAsrConfig.default // FluidAudio's config wrapper
            let manager = SlidingWindowAsrManager(config: config)
            try await manager.loadModels(from: modelDir.path)

            self.asrModels = nil
            self.asrManager = manager
            self.isReady = true
        } catch {
            throw ParakeetASRError.modelLoadFailed(underlying: error)
        }
    }

    public func unload() async {
        updatesTask?.cancel()
        if let manager = asrManager {
            await manager.cleanup()
        }
        asrManager = nil
        asrModels = nil
        isReady = false
        isStreaming = false
        partialBuffer = ""
    }

    // MARK: Streaming

    public func startStreaming(language: ASRLanguage) async throws {
        guard let manager = asrManager, isReady else {
            throw ParakeetASRError.notPrepared
        }
        partialBuffer = ""
        isStreaming = true

        do {
            try await manager.startStreaming()
            
            // Start listening to the updates stream
            updatesTask = Task { [weak self] in
                for await update in await manager.transcriptionUpdates {
                    guard let self else { return }
                    // Reconstruct the full string since the stream returns diffs or current state
                    let confirmed = await manager.confirmedTranscript
                    let volatile = await manager.volatileTranscript
                    
                    let combined = [confirmed, volatile]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")

                    let isEOU = combined.hasSuffix(".") || combined.hasSuffix("?") || combined.hasSuffix("!")
                    
                    let asrResult = ASRResult(
                        text: combined,
                        confidence: update.confidence,
                        isEndOfUtterance: isEOU,
                        providerName: self.name
                    )
                    
                    await MainActor.run {
                        self.onResult?(asrResult)
                        if isEOU {
                            self.onEndOfUtterance?()
                        }
                    }
                }
            }
        } catch {
            throw ParakeetASRError.streamingFailed(underlying: error)
        }
    }

    public func appendAudioSamples(_ samples: [Float]) async throws {
        guard isStreaming, let manager = asrManager else { return }
        
        let frameCapacity = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCapacity) else { return }
        
        buffer.frameLength = frameCapacity
        if let channelData = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                if let baseAddress = ptr.baseAddress {
                    channelData.update(from: baseAddress, count: samples.count)
                }
            }
        }
        
        await manager.streamAudio(buffer)
    }

    public func flush() async {
        // Parakeet auto-flushes based on its internal VAD or on stopStreaming().
    }

    public func stopStreaming() async throws {
        guard isStreaming, let manager = asrManager else { return }
        isStreaming = false
        updatesTask?.cancel()
        _ = try? await manager.finish()
    }
}
