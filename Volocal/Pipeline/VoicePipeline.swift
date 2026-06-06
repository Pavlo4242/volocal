// Volocal/Pipeline/VoicePipeline.swift
// Protocol-driven voice pipeline.
//
// Changes from original:
//   • Holds ASRProvider and LLMProvider protocols — no concrete llama.cpp or
//     Parakeet types leak into this file.
//   • Observes MemoryPressureMonitor and hot-swaps the LLM tier when needed.
//   • Sequential loading: STT first, LLM only on first speech detected.
//   • ScenePhase.background → LLM unloads to free GPU memory.
//   • Thai and multilingual support via WhisperASRProvider without any
//     pipeline logic changes.
//
// Pipeline flow (unchanged from original):
//   Mic → SharedAudioEngine → ASRProvider → VoicePipeline → LLMProvider
//                                    ↑                           │
//                               barge-in               SentenceBuffer
//                                                           ↓
//                                                     PocketTTSManager → Speaker

import Foundation
import SwiftUI
import Combine
import FluidAudio    // PocketTtsManager, VadManager
import AVFoundation

// MARK: - Pipeline State

public enum PipelineState: String, Equatable {
    case idle
    case listening          // ASR active, waiting for speech
    case transcribing       // ASR processing
    case processing
    case thinking           // LLM generating
    case speaking           // TTS outputting
    case error

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .transcribing: return "Transcribing..."
        case .processing: return "Processing..."
        case .thinking: return "Thinking..."
        case .speaking: return "Speaking..."
        case .error: return "Error"
        }
    }
}

// MARK: - Conversation Turn

public struct ConversationTurn: Identifiable {
    public let id = UUID()
    public let role: ChatMessage.Role
    public var content: String
    public let timestamp: Date
    public let asrProvider: String?   // for debug overlay

    public init(role: ChatMessage.Role, content: String, asrProvider: String? = nil) {
        self.role = role
        self.content = content
        self.timestamp = .now
        self.asrProvider = asrProvider
    }
}

// MARK: - VoicePipeline

@MainActor
public final class VoicePipeline: ObservableObject {

    // MARK: Published UI State

    @Published public private(set) var state: PipelineState = .idle
    @Published public var loadingStatus: String?
    @Published public var currentError: String?
    @Published public private(set) var conversation: [ConversationTurn] = []
    @Published public private(set) var partialTranscript: String = ""
    @Published public private(set) var partialResponse: String = ""
    @Published public private(set) var tokensPerSecond: Double = 0
    @Published public var isReady: Bool = false
    @Published public private(set) var isLLMLoaded = false

    // MARK: Dependencies (protocol types only)

    private var asrProvider: any ASRProvider
    private var llmProvider: any LLMProvider
    private let ttsManager: PocketTtsManager
    private let audioEngine: SharedAudioEngine
    private let memoryMonitor: MemoryPressureMonitor
    private var config: ModelConfiguration

    // MARK: Private State

    private var currentTurnRevision = 0
    private var llmTask: Task<Void, Never>?
    private var sentenceBuffer = SentenceBuffer()
    private var historyMessages: [ChatMessage] = []
    private var cancellables = Set<AnyCancellable>()
    private var llmLoadTask: Task<Void, Never>?

   // MARK: System Prompt

    private var systemPrompt: String

    // MARK: Init

    init(
        config: ModelConfiguration = .current
    ) {
        self.config = config
        self.audioEngine = SharedAudioEngine()
        self.memoryMonitor = MemoryPressureMonitor()

        if config.asrLanguage == .thai {
            self.systemPrompt = """
            You are a real-time translator. The user will speak to you in Thai.
            Translate their speech into natural-sounding English.
            Respond ONLY with the English translation. Do not add any conversational filler or explanations.
            """
        } else {
            self.systemPrompt = """
            You are a helpful voice assistant. Respond concisely in 1–3 sentences.
            Match the language of the user's message.
            """
        }

        // Instantiate concrete providers from configuration
        self.asrProvider = config.makeASRProvider()
        self.llmProvider = config.makeLLMProvider()
        self.ttsManager = PocketTtsManager()

        bindMemoryMonitor()
    }

    public func resetChat() {
        conversation.removeAll()
        historyMessages.removeAll()
        partialTranscript = ""
        partialResponse = ""
    }

    // MARK: Lifecycle

    /// Prepare STT and TTS.  Defer LLM load until first speech detected.
    public func start() async throws {
        // 1. Warm up STT
        try await asrProvider.prepare()
        wireASRCallbacks()

        // 2. Warm up TTS
        try await ttsManager.initialize()

        // 3. Start audio capture
        audioEngine.onAudioBuffer = { [weak self] samples in
            Task { [weak self] in
                try? await self?.asrProvider.appendAudioSamples(samples)
            }
        }
        audioEngine.start()
        audioEngine.beginInputCapture()

        // 4. Begin ASR (lazy LLM load below)
        try await asrProvider.startStreaming(language: config.asrLanguage)
        state = .listening
    }

    public func stop() async {
        try? await asrProvider.stopStreaming()
        llmTask?.cancel()
        await llmProvider.unload()
        audioEngine.stop()
        state = .idle
        isLLMLoaded = false
    }

    // MARK: Configuration Hot-Swap

    /// Swap ASR/LLM providers at runtime (e.g., when user changes language).
    public func reconfigure(with newConfig: ModelConfiguration) async throws {
        guard newConfig != config else { return }

        let wasListening = state == .listening

        // Teardown current providers
        try? await asrProvider.stopStreaming()
        await asrProvider.unload()
        await llmProvider.unload()
        isLLMLoaded = false

// Rebuild
        config = newConfig
        asrProvider = newConfig.makeASRProvider()
        llmProvider = newConfig.makeLLMProvider()

        if newConfig.asrLanguage == .thai {
            systemPrompt = """
            You are a real-time translator. The user will speak to you in Thai.
            Translate their speech into natural-sounding English.
            Respond ONLY with the English translation. Do not add any conversational filler or explanations.
            """
        } else {
            systemPrompt = """
            You are a helpful voice assistant. Respond concisely in 1–3 sentences.
            Match the language of the user's message.
            """
        }

        try await asrProvider.prepare()
        wireASRCallbacks()

        if wasListening {
            try await asrProvider.startStreaming(language: newConfig.asrLanguage)
            state = .listening
        }

        ModelConfiguration.current = newConfig
    }

    // MARK: App Lifecycle — Background / Foreground

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Unload the LLM to free ~1.26 GB of GPU memory.
            // Re-load lazily when user returns and speaks.
            llmTask?.cancel()
            Task { [weak self] in
                await self?.llmProvider.unload()
                await MainActor.run { self?.isLLMLoaded = false }
            }
        case .active:
            // ASR stays warm.  LLM will reload on next EOU event.
            break
        default:
            break
        }
    }

    // MARK: Barge-In

    public func bargeIn() {
        currentTurnRevision += 1
        llmTask?.cancel()
        Task { await ttsManager.stop() }
        sentenceBuffer.clear()
        partialResponse = ""
        state = .listening
    }

    // MARK: Private — ASR Callbacks

    private func wireASRCallbacks() {
        asrProvider.onResult = { [weak self] result in
            guard let self else { return }
            self.partialTranscript = result.text
            if result.isEndOfUtterance {
                self.handleEndOfUtterance(text: result.text, providerName: result.providerName)
            }
        }
        asrProvider.onEndOfUtterance = { /* handled in onResult */ }
        asrProvider.onError = { [weak self] error in
            print("[ASR] Error: \(error)")
            self?.state = .error
        }
    }

    // MARK: Private — EOU → LLM → TTS

    private func handleEndOfUtterance(text: String, providerName: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let revision = currentTurnRevision
        let userTurn = ConversationTurn(role: .user, content: text, asrProvider: providerName)
        conversation.append(userTurn)
        historyMessages.append(ChatMessage(role: .user, content: text))
        partialTranscript = ""
        state = .thinking

        llmTask = Task { [weak self] in
            guard let self else { return }

            // Lazy-load the LLM on first use
            if !self.isLLMLoaded {
                do {
                    try await self.llmProvider.prepare()
                    self.isLLMLoaded = true
                } catch {
                    print("[LLM] Load failed: \(error)")
                    self.state = .error
                    return
                }
            }

            guard !Task.isCancelled, self.currentTurnRevision == revision else { return }

            let assistantTurn = ConversationTurn(role: .assistant, content: "")
            self.conversation.append(assistantTurn)
            let assistantIdx = self.conversation.count - 1

            var fullResponse = ""
            var sentenceAcc = ""

            let stream = self.llmProvider.generate(
                messages: self.historyMessages,
                systemPrompt: self.systemPrompt
            )

            do {
                for try await token in stream {
                    guard !Task.isCancelled, self.currentTurnRevision == revision else { break }

                    if token.isLast { break }
                    fullResponse += token.text
                    sentenceAcc += token.text
                    self.partialResponse = fullResponse
                    self.conversation[assistantIdx].content = fullResponse
                    self.tokensPerSecond = self.llmProvider.tokensPerSecond

                    // Feed sentence chunks to TTS as they complete
                    if let sentence = self.sentenceBuffer.append(token.text) {
                        self.state = .speaking
                        let audio = try await self.ttsManager.synthesize(text: sentence)
                        self.audioEngine.scheduleTTSBuffer(audio)
                    }
                }
            } catch {
                if !Task.isCancelled { print("[LLM] Generation error: \(error)") }
            }

            guard !Task.isCancelled, self.currentTurnRevision == revision else { return }

            // Flush remaining partial sentence
            if let remainder = self.sentenceBuffer.flush(), !remainder.isEmpty {
                let audio = try? await self.ttsManager.synthesize(text: remainder)
                if let audio { self.audioEngine.scheduleTTSBuffer(audio) }
            }

            self.historyMessages.append(ChatMessage(role: .assistant, content: fullResponse))
            self.partialResponse = ""
            self.state = .listening

            // Resume ASR for next turn
            try? await self.asrProvider.startStreaming(language: self.config.asrLanguage)
        }
    }

    // MARK: Private — Memory Monitor Binding

    private func bindMemoryMonitor() {
        memoryMonitor.onTierChange = { [weak self] newTier in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only switch if LLM is not currently mid-generation
                guard self.state != .thinking && self.state != .speaking else { return }
                let newLLMBackend: LLMBackend = newTier == .lite ? .qwen0_8B : .qwen2B
                guard newLLMBackend.rawValue != self.config.llmBackend.rawValue else { return }
                let newConfig = ModelConfiguration(
                    asrBackend: self.config.asrBackend,
                    asrLanguage: self.config.asrLanguage,
                    llmBackend: newLLMBackend
                )
                try? await self.reconfigure(with: newConfig)
            }
        }

        memoryMonitor.onCriticalPressure = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Critical: unload LLM immediately if not generating
                if self.state == .listening || self.state == .idle {
                    self.llmTask?.cancel()
                    await self.llmProvider.unload()
                    self.isLLMLoaded = false
                }
            }
        }
    }
}

extension PocketTtsManager {
    public func initialize() async throws {
        // Warm-up handled by SharedAudioEngine
    }

    public func stop() {
        // Handled directly by SharedAudioEngine
    }
    
    public func synthesize(text: String) async throws -> [Float] {
        var allSamples: [Float] = []
        let stream = try await self.synthesizeStreaming(text: text, voice: "alba", temperature: 0.4)
        for try await frame in stream {
            allSamples.append(contentsOf: frame.samples)
        }
        return allSamples
    }
}