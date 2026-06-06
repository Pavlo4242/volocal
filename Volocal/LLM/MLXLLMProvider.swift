// Volocal/LLM/MLXLLMProvider.swift
import Foundation
import MLX
import MLXLMCommon
import Tokenizers
import Combine

public final class MLXLLMProvider: LLMProvider {
    public var isLoaded: Bool = false
    public var tokensPerSecond: Double = 0.0
    
    private let tier: LLMMemoryTier
    private var modelContext: ModelContext?
    private var generateTask: Task<Void, Error>?
    
    public init(tier: LLMMemoryTier) {
        self.tier = tier
    }
    
    public func prepare() async throws {
        guard !isLoaded else { return }
        
        // Use the ModelRegistry to get the correct path or repo.
        // For demonstration, we assume ModelRegistry+Thai's MLX model identifier is used.
        // In a real app, you'd download the model to a local URL first and load it.
        // let modelURL = ... // Path to local safetensors directory
        // modelContext = try await ModelFactory.shared.load(url: modelURL)
        
        isLoaded = true
    }
    
    public func generate(messages: [ChatMessage], systemPrompt: String) -> AsyncThrowingStream<LLMToken, Error> {
        return AsyncThrowingStream { continuation in
            generateTask = Task {
                do {
                    guard let context = modelContext else {
                        // Throw if model isn't prepared, but for the stub we will fallback to a simulated error
                        // throw LLMError.notPrepared
                        continuation.finish()
                        return
                    }
                    
                    // Format prompt
                    let prompt = systemPrompt + "\n" + messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                    
                    let inputTokens = try await context.tokenizer.encode(text: prompt)
                    var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                    
                    let parameters = GenerateParameters(temperature: 0.7)
                    let startTime = Date()
                    var tokenCount = 0
                    
                    try await MLXLMCommon.generate(
                        input: inputTokens,
                        parameters: parameters,
                        context: context
                    ) { tokens in
                        guard !Task.isCancelled else { return .stop }
                        
                        for token in tokens {
                            detokenizer.append(token: token)
                            if let chunk = detokenizer.next() {
                                continuation.yield(LLMToken(text: chunk, isLast: false))
                            }
                            tokenCount += 1
                        }
                        return .more
                    }
                    
                    // Flush the remaining token from detokenizer
                    if let finalChunk = detokenizer.last() {
                        continuation.yield(LLMToken(text: finalChunk, isLast: true))
                    } else {
                        continuation.yield(LLMToken(text: "", isLast: true))
                    }
                    
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        self.tokensPerSecond = Double(tokenCount) / elapsed
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    public func unload() async {
        generateTask?.cancel()
        modelContext = nil
        isLoaded = false
    }
}
