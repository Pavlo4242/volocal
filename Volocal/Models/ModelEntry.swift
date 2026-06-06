// Volocal/Models/ModelEntry.swift
// Describes a downloadable model asset used by ModelRegistry and OnboardingView.

import Foundation

/// A single downloadable model entry in the registry.
public struct ModelEntry: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String
    public let sizeBytes: Int
    public let huggingFaceRepo: String
    public let filename: String
    public let isDirectory: Bool
    public let requiredFor: [ASRLanguage]

    public init(
        id: String,
        displayName: String,
        description: String,
        sizeBytes: Int,
        huggingFaceRepo: String,
        filename: String,
        isDirectory: Bool = false,
        requiredFor: [ASRLanguage] = [.english]
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.sizeBytes = sizeBytes
        self.huggingFaceRepo = huggingFaceRepo
        self.filename = filename
        self.isDirectory = isDirectory
        self.requiredFor = requiredFor
    }

    /// Size formatted for display (e.g. "1.26 GB", "290 MB")
    public var formattedSize: String {
        let mb = sizeBytes / 1_048_576
        if mb >= 1024 {
            return String(format: "%.2f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }
}

// MARK: - Built-in Model Entries

extension ModelEntry {
    /// Parakeet EOU 320 — FluidAudio streaming ASR (English, ANE).
    static let parakeetEou = ModelEntry(
        id: "parakeet-eou-320",
        displayName: "Parakeet EOU (English ASR)",
        description: "FluidAudio streaming ASR via CoreML on the Apple Neural Engine.",
        sizeBytes: 450 * 1_048_576,
        huggingFaceRepo: "FluidInference/parakeet-eou-320",
        filename: "parakeet-eou-320",
        isDirectory: true,
        requiredFor: [.english]
    )

    /// Qwen 2B — standard quality LLM.
    static let qwen2B = ModelEntry(
        id: "qwen3.5-2b-q4ks",
        displayName: "Qwen3.5-2B (Standard LLM, 1.26 GB)",
        description: "Standard quality language model for voice assistant responses.",
        sizeBytes: 1260 * 1_048_576,
        huggingFaceRepo: "bartowski/Qwen_Qwen3.5-2B-GGUF",
        filename: "Qwen3.5-2B-Q4_K_S.gguf",
        isDirectory: false,
        requiredFor: [.english, .thai]
    )

    /// PocketTTS — FluidAudio text-to-speech.
    static let pocketTTS = ModelEntry(
        id: "pocket-tts",
        displayName: "PocketTTS (Text-to-Speech)",
        description: "FluidAudio on-device streaming TTS via CoreML.",
        sizeBytes: 600 * 1_048_576,
        huggingFaceRepo: "FluidInference/pocket-tts",
        filename: "pocket-tts",
        isDirectory: true,
        requiredFor: [.english, .thai]
    )
}
