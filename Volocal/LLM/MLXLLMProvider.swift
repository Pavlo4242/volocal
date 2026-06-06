// Volocal/LLM/MLXLLMProvider.swift
// MLX Swift adapter — hardware-accelerated LLM on Apple Silicon.
//
// Uses mlx-swift-lm (MLXLMCommon + MLXLLM) for tokenization, generation,
// and streaming detokenization.

import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace

public final class MLXLLMProvider: LLMProvider {

    // MARK: LLMProvider conformance

    public let name: String
    public var estimatedMemoryMB: Int { tier == .standard ? 1260 : 520 }
    public let maxContextTokens: Int = 4096
    public private(set) var isReady: Bool = false
    public private(set) var tokensPerSecond: Double = 0.0

    // MARK: Private State

    private let tier: LLMMemoryTier
    private var modelContainer: ModelContainer?
    private var generateTask: Task<Void, Error>?
    private var isCancelled = false

    // MARK: Init

    public init(tier: LLMMemoryTier) {
        self.tier = tier
        self.name = "MLX Swift / \(tier == .standard ? "Qwen 2B" : "Qwen 0.5B")"
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        guard !isReady else { return }

        // Use the MLXLMCommon free function to load a model container.
        // The hub ID references a pre-quantized MLX model on HuggingFace.
        let hubID = tier == .standard
            ? "mlx-community/Qwen1.5-1.8B-Chat-4bit"
            : "mlx-community/Qwen1.5-0.5B-Chat-4bit"

        // Create an MLXLMCommon.ModelConfiguration (fully qualified to avoid
        // collision with Volocal's own ModelConfiguration struct).
        let mlxConfig = MLXLMCommon.ModelConfiguration(id: hubID)

        // loadModelContainer is a free function in MLXLMCommon that:
        //   1. Resolves the model via the HubApi downloader
        //   2. Loads weights + tokenizer
        //   3. Returns a thread-safe ModelContainer actor
        modelContainer = try await #huggingFaceLoadModelContainer(
            configuration: mlxConfig
        )

        isReady = true
    }

    public func unload() async {
        generateTask?.cancel()
        modelContainer = nil
        isReady = false
    }

    // MARK: Generation

    public func generate(
        messages: [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<LLMToken, Error> {

        isCancelled = false

        return AsyncThrowingStream { continuation in
            generateTask = Task { [weak self] in
                guard let self, let container = self.modelContainer else {
                    continuation.finish()
                    return
                }

                do {
                    let prompt = self.buildPrompt(systemPrompt: systemPrompt, messages: messages)
                    let startTime = Date()
                    var tokenCount = 0

                    // ModelContainer.perform gives us exclusive access to the
                    // non-Sendable ModelContext inside the actor.
                    let _ = try await container.perform { context in
                        let input = try await context.processor.prepare(
                            input: .init(prompt: prompt)
                        )

                        return try MLXLMCommon.generate(
                            input: input,
                            parameters: .init(temperature: 0.7, topP: 0.9),
                            context: context
                        ) { tokens -> GenerateDisposition in
                            guard !Task.isCancelled, !self.isCancelled else { return .stop }

                            tokenCount += 1
                            let newText = context.tokenizer.decode(tokenIds: tokens)
                            // newText is the full decoded string so far; we need the delta.
                            // But generate() gives us the full token array each call, so
                            // decode just the latest token for the delta.
                            let latestToken = [tokens.last].compactMap { $0 }
                            let delta = context.tokenizer.decode(tokenIds: latestToken)

                            if !delta.isEmpty {
                                continuation.yield(LLMToken(text: delta, isLast: false))
                            }

                            return tokenCount >= 512 ? .stop : .more
                        }
                    }

                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        self.tokensPerSecond = Double(tokenCount) / elapsed
                    }

                    continuation.yield(LLMToken(text: "", isLast: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancelGeneration() {
        isCancelled = true
        generateTask?.cancel()
    }

    // MARK: Private — Prompt Building

    private func buildPrompt(systemPrompt: String, messages: [ChatMessage]) -> String {
        let trimmed = trimmedMessages(messages)
        var parts: [String] = []
        parts.append("<|im_start|>system\n\(systemPrompt)<|im_end|>")
        for msg in trimmed {
            let role = msg.role == .user ? "user" : "assistant"
            parts.append("<|im_start|>\(role)\n\(msg.content)<|im_end|>")
        }
        parts.append("<|im_start|>assistant\n")
        return parts.joined(separator: "\n")
    }
}
