// Volocal/LLM/FoundationModelProvider.swift
// Apple Foundation Models adapter — zero-GGUF LLM path for iOS 26+.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - FoundationModelProvider

public final class FoundationModelProvider: LLMProvider {

    public let name = "Apple Foundation Models (iOS 26+)"
    public let maxContextTokens = 8192
    public var estimatedMemoryMB: Int { 0 }   // managed by system daemon
    public private(set) var tokensPerSecond: Double = 0
    public private(set) var isReady = false

    private var isCancelled = false
    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    public init() {}

    // MARK: Availability Check

    /// Returns true when Foundation Models are available and eligible on this device.
    public static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 15, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 15, *) {
            // FoundationModels loads lazily — just mark ready.
            isReady = true
            return
        }
        #endif
        isReady = false
    }

    public func unload() async {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 15, *) {
            session = nil
        }
        #endif
        isReady = false
    }

    // MARK: Generation

    public func generate(
        messages: [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<LLMToken, Error> {

        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 15, *) {
                Task {
                    do {
                        // 1. Build a FoundationModels session
                        let instructions = Instructions(systemPrompt)
                        var transcript = Transcript()
                        
                        let trimmed = self.trimmedMessages(messages)
                        
                        // Drop the last user message to avoid duplicating it in the transcript context
                        let history = trimmed.dropLast()
                        
                        for msg in history {
                            switch msg.role {
                            case .user:
                                transcript.append(.prompt(msg.content))
                            case .assistant:
                                transcript.append(.response(msg.content))
                            case .system:
                                break  // handled entirely by Instructions
                            }
                        }

                        let newSession = LanguageModelSession(
                            instructions: instructions,
                            transcript: transcript
                        )
                        self.session = newSession

                        let lastUser = trimmed.last(where: { $0.role == .user })?.content ?? ""
                        let startTime = Date()
                        var nTokens = 0
                        var previousLength = 0

                        // 2. Stream snapshots and convert to deltas
                        // Foundation Models stream the full string snapshot on every yield.
                        // Volocal's VoicePipeline expects string deltas, so we must calculate the diff.
                        for try await snapshot in newSession.streamResponse(to: lastUser) {
                            guard !self.isCancelled else { break }
                            
                            let currentText = String(describing: snapshot)
                            let delta = String(currentText.dropFirst(previousLength))
                            previousLength = currentText.count
                            
                            nTokens += 1
                            continuation.yield(LLMToken(text: delta, isLast: false))
                        }

                        let elapsed = Date().timeIntervalSince(startTime)
                        if elapsed > 0 { self.tokensPerSecond = Double(nTokens) / elapsed }

                        continuation.yield(LLMToken(text: "", isLast: true))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            } else {
                continuation.finish(throwing: FoundationModelError.unavailable)
            }
            #else
            continuation.finish(throwing: FoundationModelError.unavailable)
            #endif
        }
    }

    public func cancelGeneration() {
        isCancelled = true
        // The session object does not have a public cancel method in the current API,
        // so we handle it gracefully via the isCancelled boolean guard in the stream loop.
    }
}

// MARK: - Error

enum FoundationModelError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Apple Foundation Models require iOS 26+ / macOS 15+ and Apple Intelligence eligibility."
    }
}