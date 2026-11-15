# Edu

Offline-first peer-to-peer study and interactive whiteboard tutor.

## Architecture

The application follows Clean Architecture. Domain contracts live under `lib/features`, while the composition layer selects a tutor engine for `standaloneHost`, `lanCompanion`, or `lightEdge` execution. Platform-specific inference and transport are kept behind repository/service interfaces.

## Phase 1 foundation

Phase 1 defines the execution modes, typed application failures, tutor engine domain contract, immutable whiteboard synchronization schema, and the GBNF grammar used to constrain model output. The model validates untrusted JSON and enforces normalized coordinates and the `uint32` step identifier required by the LAN audio framing protocol.

## Phase 2 whiteboard

The whiteboard uses normalized board coordinates, a canonical target-keyed `BoardStateTracker`, audio-output-frame scheduling with FIFO step cancellation on barge-in, cached `PathMetric` rendering, pressure-sensitive ink via `perfect_freehand`, positioned LaTeX overlays, and explicit PNG export through a keyed `RepaintBoundary`. Snapshot capture is opt-in and should be invoked only for a student feedback request.

## Phase 3 LAN companion

The execution-mode pairing screen offers standalone host, LAN companion, and light-edge modes. Hosts advertise `_neuraltutor._tcp`, issue a cryptographically random 256-bit Bearer key and six-digit PIN, and serve authenticated Shelf WebSockets. Incoming PCM and snapshot JSON/base64 decoding run in a worker isolate. Downstream whiteboard steps and 16 kHz mono TTS chunks are sent as ordered batches with a four-byte big-endian step identifier. The paired repository implementation also streams mic PCM and stylus events, while the LAN database service reconciles durable student-note and serialized SQLite-vec row records using revision/device-id conflict ordering and tombstones.

Pairing QR codes contain the endpoint, key, and PIN; share them only with the intended companion. The current local-network WebSocket endpoint is not TLS-encrypted, so pairing should be limited to trusted networks. WebP conversion of an exported PNG runs in an isolate through the `image` package.

## Phase 4 native edge runtime

The native runtime layer defines validated Gemma 4 host/light-edge profiles, the `edu_runtime_*` C ABI, an Android JNI/MethodChannel bridge, persistent native-model worker isolates, incremental validated whiteboard JSON parsing, Silero-VAD/Moonshine-or-Whisper/Kokoro task routing, and a warm-model/lazy-embedding orchestrator. Speech audio is retained as bounded PCM S16LE context for multimodal prompts; each parsed `WhiteboardSyncStep` is passed to Kokoro and enqueued with its `step_id` through the audio-synchronized `PcmStepScheduler`. VAD barge-in flushes scheduled audio and invalidates any TTS result still in flight. Unit tests cover runtime profiles, model lifecycle, streaming step parsing, and voice barge-in/PCM scheduling.

The Android CMake dispatcher loads the LiteRT-LM or llama.cpp backend shared library at runtime. Those vendor backend libraries and model weights are not included in this source checkout. Actual Gemma inference, accelerator delegation, KV-cache allocation, GBNF decoding, ASR, TTS and embeddings therefore require packaging a compatible backend build. The channel/FFI interfaces fail explicitly when a compatible backend is absent.

## Phase 5 host/companion, curriculum RAG and app shell

`LocalTutorEngineBase` routes paired companion 16 kHz mono PCM, normalized stylus events, WebP snapshots, prompts and interrupts into the host engine. A requested board-grading action captures and converts a snapshot only on demand. Host-generated steps are sent through `LocalHostServer.sendSynchronizedStep` as an ordered JSON `whiteboard_step`, one or more binary frames (`4-byte big-endian step ID + S16LE PCM`), then `audio_end`.

`lib/features/rag_notes/` includes SQLite persistence for chunk text, source/document/page/section metadata, Float32 embeddings and FSRS review state; text/Markdown parsing and basic text-layer PDF extraction; cited top-K cosine retrieval; note-derived explicit Q/A and cloze cards; and an interactive Again/Hard/Good/Easy review screen. The multilingual embedding resource is lazy and unloaded in `finally` after each indexing or query-embedding operation. Scanned/image-only PDFs currently need OCR before ingestion. The vector store uses the optional `vec0` SQLite extension when a usable extension is configured; without one it uses an exact cosine-search fallback over its stored vectors. The current app does **not** bundle a sqlite-vec binary, so package a matching SQLite extension and configure `sqliteVecExtensionPathProvider` to enable vec0 acceleration.

`main.dart` starts the Material 3 application in `ProviderScope`. `HomeShell` provides a responsive phone/tablet rail/navigation layout for live tutor and whiteboard controls, local curriculum/flashcards, and execution-mode QR/PIN pairing. The app composition boundary is `tutorEngineRuntimeDependenciesProvider`: the platform host must override it with installed model paths, the native worker driver, microphone PCM capture, the device's audio-synchronized playback sink/whiteboard controller, and (when tutor-side RAG grounding is enabled) a `CurriculumRagService`. Pairing credentials can be supplied through the Riverpod pairing state. The repository intentionally fails visibly rather than silently substituting a fake audio clock or missing runtime. Use a 16 kHz mono S16LE PCM stream; real playback scheduling must report a monotonic hardware played-frame counter.

### Model placement and installation

Model files are large and are **not** Flutter assets or Git files. Install them into app-private storage (on Android, under the path returned by `getApplicationSupportDirectory()`, for example `<app-support>/models/`) and have the app's model installer resolve absolute paths into `TutorModelPaths`:

| `TutorModelPaths` entry | Expected model role | Suggested filename |
| --- | --- | --- |
| `gemma4E4b` | Gemma 4 E4B Q4_K_M host model | `gemma-4-e4b-q4_k_m.litertlm` |
| `gemma4E2b` | Gemma 4 E2B q4_0 Light Edge profile | `gemma-4-e2b-q4_0.litertlm` |
| `sileroVad` | Silero VAD | `silero-vad.litertlm` |
| `moonshineWhisperAsr` | Arabic/English Moonshine or Whisper ASR | `moonshine-whisper-ar-en.litertlm` |
| `kokoro82m` | Kokoro-82M TTS | `kokoro-82m.litertlm` |
| `multilingualEmbedding` | BGE-M3 or multilingual E5 embeddings | `bge-m3-or-multilingual-e5.litertlm` |
| `grammar` | Included whiteboard GBNF | `<app bundle>/assets/grammar/whiteboard.gbnf` |
| `gemma4E4bGgufFallback` | Optional llama.cpp GGUF fallback | `gemma-4-e4b-fallback.gguf` |

Use only compatible, licensed model conversions for the selected LiteRT-LM/llama.cpp backend and confirm each backend's expected file format. The suggested names are conventions; the runtime receives absolute paths and does not search arbitrary shared-storage locations. For security and Android scoped-storage compatibility, keep model weights in app-private storage and provide an explicit download/import flow.

### Build and verification

Requires Flutter 3.24+ / Dart 3.5+, Android SDK/NDK and CMake 3.22.1. From the repository root:

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

Build an obfuscated, R8-minified Android App Bundle (default) or APK:

```sh
./scripts/build_android_release.sh appbundle
./scripts/build_android_release.sh apk
```

The release script runs dependency resolution and tests first, enables `--release --obfuscate --split-debug-info --tree-shake-icons`, targets Android arm64, and stores mapping/debug information under `build/symbols/android/` by default. Preserve those symbols with the corresponding release. Android release uses R8 full mode (AGP 8+ default), code shrinking, resource shrinking, JNI/native-method keep rules and the configured CMake dispatcher. The vendor backend `.so` files still need to be supplied by the product build before model inference is available.

## Five-phase architecture summary

1. **Foundation:** execution modes, tutor contracts, typed failures, validated whiteboard schema and constrained-generation grammar.
2. **Whiteboard:** normalized board state, responsive S-Pen/touch canvas, math rendering, played-frame synchronization, FIFO interruption and on-demand snapshot export.
3. **Companion sync:** QR/PIN authentication, mDNS, authenticated WebSockets, binary audio framing, stylus/snapshot transport and durable LAN synchronization.
4. **Native edge runtime:** isolate-owned JNI/FFI inference, Gemma 4 host/light profiles, voice/VAD/ASR/TTS orchestration, model lifecycle and cancellation.
5. **Host/RAG/review/app:** paired input routing and synchronized response, local cited curriculum index, lazy embeddings, FSRS flashcards, responsive app workspaces and Android release hardening.
