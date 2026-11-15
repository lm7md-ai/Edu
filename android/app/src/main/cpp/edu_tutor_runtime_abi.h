#ifndef EDU_TUTOR_RUNTIME_ABI_H_
#define EDU_TUTOR_RUNTIME_ABI_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stable C ABI consumed by FfiNativeRuntimeBridge. This dispatcher loads
 * `libedu_litert_lm_backend.so` or `libedu_llama_cpp_backend.so`; each backend
 * must export the same functions with the `edu_backend_` prefix.
 *
 * `config_json` is UTF-8 NativeRuntimeConfig JSON containing model_id,
 * model_path, backend ("liteRtLm" or "llamaCpp"), quantization,
 * accelerator ("automatic", "npu", "gpu", or "cpu"), prefer_npu,
 * context_tokens, kv_cache_quantization ("f16" or "q4_0"), grammar_path,
 * and optional llama_fallback_model_path. LiteRT-LM backends must honor the
 * accelerator preference with an available NPU/GPU delegate and fall back to
 * CPU only when their runtime policy permits. They own KV-cache allocation,
 * memory bounds, and GBNF-constrained decoding using grammar_path. The
 * dispatcher retries a failed LiteRT-LM open with llama.cpp only when an
 * explicit fallback path was supplied.
 *
 * `request_json` contains request_id, task, prompt, optional step_id,
 * audio_context_base64, and webp_snapshot_base64. Backend task names include
 * multimodal_gemma, silero_vad_16khz, moonshine_whisper_ar_en_asr,
 * kokoro_82m_tts_s16le_16khz, and multilingual_text_embedding. Implementations
 * must decode binary base64 inputs before inference and stream bounded events.
 *
 * `next_event` returns null when no event is ready, or a malloc-compatible
 * UTF-8 JSON string that must be released with free_event. Events use
 * {request_id,type,text?,step_id?,pcm_s16le?,embedding?,error?}; event types
 * include token, whiteboard_json, audio_chunk, vad_speech, vad_silence,
 * transcript, embedding, completed, and failed. PCM is an integer array of
 * signed-16-bit little-endian bytes. Cancellation must promptly stop work and
 * produce a terminal completed/failed event so polling can finish. Calls may
 * be concurrent for distinct generation ids; close must wait for native work
 * to stop before releasing the session and its KV cache.
 */
void* edu_runtime_open(const char* config_json);
int64_t edu_runtime_start_generation(void* session, const char* request_json);
char* edu_runtime_next_event(void* session, int64_t generation_id, int32_t timeout_ms);
int32_t edu_runtime_cancel_generation(void* session, int64_t generation_id);
int32_t edu_runtime_backend_available(int32_t backend_index);
void edu_runtime_free_event(char* event_json);
void edu_runtime_close(void* session);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // EDU_TUTOR_RUNTIME_ABI_H_
