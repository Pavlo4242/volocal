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
    /// Nemotron-3.5-ASR — FluidAudio streaming ASR (English, ANE).
    static let parakeetEou = ModelEntry(
        id: "qwen3-asr-0.6b-coreml",
        displayName: "Qwen3 ASR 0.6B",
        description: "FluidAudio streaming ASR via CoreML.",
        sizeBytes: 450 * 1_048_576,
        huggingFaceRepo: "FluidInference/qwen3-asr-0.6b-coreml",
        filename: "qwen3-asr-0.6b-coreml",
        isDirectory: true,
        requiredFor: [.english]
    )

    /// Qwen 2B — standard quality LLM.
    static let qwen2B = ModelEntry(
        id: "typhoon-translate-4b-mlx-4bit",
        displayName: "Typhoon Translate 4B",
        description: "Language model for voice assistant responses.",
        sizeBytes: 2500 * 1_048_576,
        huggingFaceRepo: "typhoon-ai/typhoon-translate-4b-mlx-4bit",
        filename: "typhoon-translate-4b-mlx-4bit",
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
