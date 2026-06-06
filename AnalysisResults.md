# Volocal Codebase Analysis — Refactoring Plan vs. Actual Code

Comprehensive audit of every source file against the [REFACTORING_PLAN.md](file:///c:/Users/Cray/New%20folder/volocal/REFACTORING_PLAN.md). This document catalogs all compile errors, API mismatches, missing types, and integration gaps.

---

## 🔴 Critical Compile Errors (Will Prevent Build)

### 1. `VoicePipeline` — Old vs. New API Schism

The refactored [VoicePipeline.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift) has a **completely different public API** from what the old view files expect.

| Symbol | Old API (expected by views) | New API (actual in VoicePipeline) | Files affected |
|---|---|---|---|
| `pipeline.conversationHistory` | `[ConversationMessage]` | Does not exist — now `conversation: [ConversationTurn]` | [PipelineView.swift:L14](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L14), [L32](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L32), [L93](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L93) |
| `pipeline.currentResponse` | `String` | Does not exist — now `partialResponse: String` | [PipelineView.swift:L20](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L20), [L23](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L23), [L37](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L37) |
| `pipeline.currentError` | `String?` | Does not exist | [PipelineView.swift:L59](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L59), [ModelLoadingView.swift:L20](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/ModelLoadingView.swift#L20) |
| `pipeline.toggleListening()` | method | Does not exist — now `start()`/`stop()` | [PipelineView.swift:L68](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L68) |
| `pipeline.resetChat()` | method | Does not exist | [PipelineView.swift:L89](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L89) |
| `pipeline.isReady` | `Bool` | Does not exist | [VolocalApp.swift:L15](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/VolocalApp.swift#L15) |
| `pipeline.loadingStatus` | `String?` | Does not exist | [ModelLoadingView.swift:L13](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/ModelLoadingView.swift#L13) |
| `pipeline.metrics` | `SystemMetrics?` | Does not exist | [VolocalApp.swift:L19](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/VolocalApp.swift#L19) |
| `pipeline.configure(llmModelPath:)` | method | Does not exist — now `init(config:audioEngine:memoryMonitor:)` | [VolocalApp.swift:L21-23](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/VolocalApp.swift#L21-L23) |

> [!CAUTION]
> This is the single most critical issue. **PipelineView, ModelLoadingView, and VolocalApp will not compile at all** because they reference ~10 properties/methods that don't exist on the refactored VoicePipeline.

---

### 2. `PipelineView` — Missing `PipelineState` Enum Cases

[PipelineView.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift) uses `.processing` and `.idle` in its switch statements (lines 20, 100-105, 108-114), but the refactored [PipelineState](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L28-L35) enum defines:

```swift
public enum PipelineState: String, Equatable {
    case idle
    case listening
    case transcribing    // NEW — not in old PipelineView
    case thinking        // NEW — replaces .processing
    case speaking
    case error           // NEW — not in old PipelineView
}
```

**Mismatches:**
- Old PipelineView uses `.processing` → should be `.thinking` or `.transcribing`
- Old PipelineView has no cases for `.transcribing` and `.error` → **non-exhaustive switch** compile error in `buttonColor` and `buttonIcon`

---

### 3. `PipelineView` References `ConversationMessage` — Should Be `ConversationTurn`

[MessageBubble](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L120-L137) at line 121 declares `let message: ConversationMessage` but the refactored VoicePipeline publishes `[ConversationTurn]`, not `[ConversationMessage]`. The old `ConversationMessage` type (in [ConversationModel.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Models/ConversationModel.swift)) uses `.role` with `Role { case user, assistant }` while `ConversationTurn` uses `ChatMessage.Role` with `{ case system, user, assistant }`.

---

### 4. `VolocalApp` — Incompatible VoicePipeline Initialization

[VolocalApp.swift:L7](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/VolocalApp.swift#L7):
```swift
@StateObject private var pipeline = VoicePipeline()
```

But the refactored `VoicePipeline.init` requires 3 arguments:
```swift
public init(
    config: ModelConfiguration = .current,
    audioEngine: SharedAudioEngine,      // REQUIRED — no default
    memoryMonitor: MemoryPressureMonitor // REQUIRED — no default
)
```

> [!CAUTION]
> This is a hard compile error. `VoicePipeline()` with no arguments is invalid.

---

### 5. `LlamaContext.swift` — Wrong Module Import

[LlamaContext.swift:L2](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/LlamaContext.swift#L2) imports `LlamaSwift`, but [project.yml](file:///c:/Users/Cray/New%20folder/volocal/project.yml#L37) declares the product as `Llama` (from the `llama.swift` package). The [LlamaLLMProvider.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/LlamaLLMProvider.swift#L18) correctly imports `Llama`.

**Fix needed:** Change `import LlamaSwift` → `import Llama` in LlamaContext.swift, or verify the actual module name exported by the `llama.swift` SPM package. Both files must use the same module name.

---

### 6. `SentenceBuffer` — API Contract Mismatch with VoicePipeline

[VoicePipeline.swift:L278](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L278) calls:
```swift
if let sentence = self.sentenceBuffer.append(token.text) { ... }
```

But [SentenceBuffer.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/SentenceBuffer.swift#L16) has:
```swift
func append(_ token: String)  // returns Void, not String?
```

The `append()` method uses a **callback pattern** (`onSentenceReady`) instead of returning a value. Similarly, [VoicePipeline.swift:L291](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L291) calls `sentenceBuffer.flush()` expecting an optional `String?` return, but the real `flush()` returns `Void` (also uses callback).

Additionally, VoicePipeline calls `sentenceBuffer.clear()` at line 203, but SentenceBuffer only has `reset()`.

---

## 🟠 Major API / Integration Issues

### 7. `VoicePipeline` Uses `PocketTtsManager` Directly — Wrong API

[VoicePipeline.swift:L109](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L109):
```swift
self.ttsManager = PocketTtsManager(language: .english)
```

But the existing [TTSManager.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/TTS/TTSManager.swift) wraps `PocketTtsManager` and provides the app-level API. VoicePipeline:
- Calls `ttsManager.initialize()` at L123 — `PocketTtsManager` from FluidAudio may not have this exact signature
- Calls `ttsManager.synthesize(text:)` at L280 expecting a return value — FluidAudio's API is `synthesizeStreaming(text:voice:)` returning an `AsyncThrowingStream`
- Calls `ttsManager.stop()` at L202 — may or may not exist on FluidAudio's `PocketTtsManager`
- Calls `audioEngine.playAudio(audio)` at L281 — `SharedAudioEngine` has `scheduleTTSBuffer(_ samples: [Float])`, not `playAudio()`

> [!IMPORTANT]
> The VoicePipeline's TTS integration is written against a hypothetical API that doesn't match either FluidAudio's `PocketTtsManager` or the app's `TTSManager` wrapper.

---

### 8. `SharedAudioEngine` — Missing `onAudioBuffer` and `start()` API

[VoicePipeline.swift:L126-131](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L126-L131):
```swift
audioEngine.onAudioBuffer = { ... }   // Does not exist on SharedAudioEngine
try audioEngine.start()                // start() returns Void, not throwing
```

[SharedAudioEngine](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Audio/SharedAudioEngine.swift):
- Has no `onAudioBuffer` property — uses `AudioBridge.inputContinuation` to send `AVAudioPCMBuffer` objects via `AsyncStream`
- `start()` is non-throwing (line 50)
- Has no `playAudio()` method

VoicePipeline feeds `[Float]` samples but SharedAudioEngine's input path works with `AVAudioPCMBuffer` objects.

---

### 9. `ModelRegistry+Thai` — References to Non-Existent `ModelEntry` Properties

[ModelRegistry+Thai.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/ModelRegistry+Thai.swift) references:
- `ModelEntry` struct/class with init `(id:displayName:description:sizeBytes:huggingFaceRepo:filename:isDirectory:requiredFor:)` — this type does not exist anywhere in the codebase
- `.parakeetEou` — referenced at L56 but not defined in [ModelRegistry.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Models/ModelRegistry.swift)
- `.qwen2B` — referenced at L66 but not defined
- `.pocketTTS` — referenced at L74 but not defined
- `requiredFor: [.thai]` / `[.english, .thai]` — suggests an enum like `ASRLanguage` but this parameter type is undefined on `ModelEntry`

> [!WARNING]
> The entire `ModelEntry` type and its predefined static entries (`.parakeetEou`, `.qwen2B`, `.pocketTTS`) need to be created. This file compiles extensions on a non-existent type.

---

### 10. `VolocalApp` — ScenePhase Not Forwarded to Pipeline

The refactored VoicePipeline has [handleScenePhaseChange()](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L179), but [VolocalApp.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/VolocalApp.swift#L33-L42) only forwards scene changes to `metrics`, not to the pipeline:

```swift
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .active:    metrics.startMonitoring()
    case .inactive, .background: metrics.stopMonitoring()
    // Missing: pipeline.handleScenePhaseChange(newPhase)
    }
}
```

---

### 11. `MemoryPressureMonitor` Is Never Started

[VolocalApp.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/VolocalApp.swift) never creates or starts a `MemoryPressureMonitor`. The refactored VoicePipeline requires one as a constructor argument. Nobody calls `memoryMonitor.start()`.

---

## 🟡 Missing Types & Declarations

### 12. `ModelEntry` Struct — Entirely Missing

Referenced by [ModelRegistry+Thai.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/ModelRegistry+Thai.swift) but never defined. Needs:
- Properties: `id`, `displayName`, `description`, `sizeBytes`, `huggingFaceRepo`, `filename`, `isDirectory`, `requiredFor`
- Static entries: `.parakeetEou`, `.qwen2B`, `.pocketTTS`

### 13. VoicePipeline Commented-Out SentenceBuffer

[VoicePipeline.swift:L339-352](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/VoicePipeline.swift#L339-L352) contains a commented-out duplicate `SentenceBuffer` block with different method signatures (`flush() -> String?`, `clear()`). This was presumably the intended API for VoicePipeline but was never implemented — the separate [SentenceBuffer.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/SentenceBuffer.swift) file has the callback-based API instead.

### 14. `VoicePipeline.state` — Label Property Missing

[PipelineView.swift:L47](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Pipeline/PipelineView.swift#L47) calls `pipeline.state.label`, but `PipelineState` has no `label` computed property. It's a raw-value enum with `String` raw values, but `.label` is not `.rawValue`.

---

## 🔵 Concurrency & Swift 6 Strict Concurrency Issues

### 15. `ASRProvider` Protocol — Not Sendable

[project.yml](file:///c:/Users/Cray/New%20folder/volocal/project.yml#L45) enables `-strict-concurrency=complete` (Swift 6 mode). The `ASRProvider` protocol requires `AnyObject` but not `Sendable`. Since VoicePipeline is `@MainActor` and ASR callbacks fire from background threads, the callback closures cross actor boundaries. The `onResult`, `onEndOfUtterance`, and `onError` closure properties on ASRProvider are not `@Sendable`, which will produce strict-concurrency warnings/errors.

### 16. `LlamaLLMProvider.generate()` — Captures `self` Across Actors

[LlamaLLMProvider.swift:L159](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/LlamaLLMProvider.swift#L159) dispatches onto `generationQueue.async` and captures `[weak self]`, then mutates `self.tokensPerSecond` from a non-MainActor DispatchQueue. Under strict concurrency, writing to an instance property from a non-isolated context will error. The class is not `@MainActor` and `tokensPerSecond` is not isolated.

### 17. `WhisperASRProvider` — `vadState` Copy Semantics

[WhisperASRProvider.swift:L175](file:///c:/Users/Cray/New%20folder/volocal/Volocal/STT/WhisperASRProvider.swift#L175): `var state = vadState` suggests `VadStreamState` is a value type. But line 184 writes back `vadState = vadResult.state`. If `VadStreamState` is actually a class (reference type), the `var` copy is fine. If it's a struct, the intermediate `var state` is unnecessary. Verify FluidAudio's `VadStreamState` type — if it's a class, strict-concurrency rules for non-Sendable types across `async` boundaries apply.

---

## 🟢 Minor Issues & Improvements

### 18. Dead Code — Old `STTManager` and `LLMManager`

[STTManager.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/STT/STTManager.swift) and [LLMManager.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/LLMManager.swift) are the **pre-refactor** concrete managers. The Refactoring Plan says they should be replaced by `ParakeetASRProvider` and `LlamaLLMProvider` respectively. However:
- `STTManager` is still referenced by `SharedAudioEngine` via `AudioBridge.inputContinuation` (designed for the old `STTManager` flow)
- Both files compile against the old VoicePipeline API
- They should be **deleted or marked deprecated** once the views are migrated

### 19. `LlamaContext.swift` vs `LlamaLLMProvider.swift` — Duplicate LLM Paths

The codebase has **two independent llama.cpp integration paths**:
1. [LlamaContext.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/LlamaContext.swift) — actor-based, used by old `LLMManager`
2. [LlamaLLMProvider.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/LlamaLLMProvider.swift) — class-based, uses raw C API directly

They're not compatible and don't share code. After migration, `LlamaContext.swift` should be deleted or `LlamaLLMProvider` should be refactored to use `LlamaContext` internally.

### 20. `FoundationModelProvider` — Speculative API

[FoundationModelProvider.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/LLM/FoundationModelProvider.swift) uses speculative iOS 26 FoundationModels API surface:
- `LanguageModelSession`, `Transcript`, `Instructions` — these are plausible but not yet verified against actual iOS 26 SDK headers
- `SystemLanguageModel.default.isAvailable` — availability API may differ
- `newSession.streamResponse(to:)` — streaming API shape is unconfirmed
- `session?.cancel()` — session cancellation API is unconfirmed

Since these are behind `#if canImport(FoundationModels)`, they won't break the build on current SDKs, but should be verified when iOS 26 SDK is available.

### 21. `MetricsOverlay` — Doesn't Show ASR Provider Name

The Refactoring Plan specifies: *"Show active ASR provider name"* in `Debug/MetricsOverlay.swift`. The current [MetricsOverlay](file:///c:/Users/Cray/New%20folder/volocal/Volocal/Debug/MetricsOverlay.swift) only shows memory, CPU, and thermal state — no ASR provider info.

### 22. `ModelConfiguration` File Location Mismatch

[ModelConfiguration.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/ModelConfiguration.swift) has a comment on line 1 saying `// Volocal/Models/ModelConfiguration.swift` but the file lives in `Volocal/App/`. Similarly, [ModelRegistry+Thai.swift](file:///c:/Users/Cray/New%20folder/volocal/Volocal/App/ModelRegistry+Thai.swift) says `// Volocal/Models/ModelRegistry+Thai.swift`. The Refactoring Plan lists these under `Models/`. Either move them or update comments.

---

## Summary: Prioritized Fix Order

| Priority | Issue | Complexity | Files to Change |
|---|---|---|---|
| 🔴 P0 | VoicePipeline init signature — VolocalApp can't compile | Medium | VolocalApp.swift |
| 🔴 P0 | VoicePipeline missing properties (isReady, currentError, loadingStatus, etc.) | Medium | VoicePipeline.swift |
| 🔴 P0 | PipelineView → wrong property names + wrong enum cases | Medium | PipelineView.swift |
| 🔴 P0 | MessageBubble uses `ConversationMessage` instead of `ConversationTurn` | Easy | PipelineView.swift |
| 🔴 P0 | SentenceBuffer API mismatch (returns Void, not String?) | Easy | SentenceBuffer.swift or VoicePipeline.swift |
| 🔴 P0 | LlamaContext.swift wrong import (`LlamaSwift` → `Llama`) | Easy | LlamaContext.swift |
| 🟠 P1 | SharedAudioEngine missing `onAudioBuffer` / `playAudio()` | Medium | SharedAudioEngine.swift + VoicePipeline.swift |
| 🟠 P1 | TTS integration — VoicePipeline uses wrong PocketTtsManager API | Medium | VoicePipeline.swift |
| 🟠 P1 | Missing `ModelEntry` type definition | Medium | New file in Models/ |
| 🟠 P1 | MemoryPressureMonitor never created/started | Easy | VolocalApp.swift |
| 🟡 P2 | PipelineState missing `.label` computed property | Easy | VoicePipeline.swift |
| 🟡 P2 | Scene phase forwarding to pipeline | Easy | VolocalApp.swift |
| 🟡 P2 | MetricsOverlay — add ASR provider name | Easy | MetricsOverlay.swift |
| 🟢 P3 | Delete dead code (STTManager, LLMManager) | Easy | Delete files |
| 🟢 P3 | Consolidate LlamaContext / LlamaLLMProvider | Medium | LLM/ directory |
| 🟢 P3 | Swift 6 strict concurrency annotations | Medium | Multiple files |
