#include "edu_tutor_runtime_abi.h"

#include <jni.h>
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {
using OpenFn = void* (*)(const char*);
using StartFn = int64_t (*)(void*, const char*);
using NextEventFn = char* (*)(void*, int64_t, int32_t);
using CancelFn = int32_t (*)(void*, int64_t);
using CloseFn = void (*)(void*);

struct BackendApi {
  void* library = nullptr;
  OpenFn open = nullptr;
  StartFn start = nullptr;
  NextEventFn next_event = nullptr;
  CancelFn cancel = nullptr;
  CloseFn close = nullptr;
};

struct RuntimeSession {
  BackendApi api;
  void* backend_session = nullptr;
};

bool bind_backend(BackendApi* api, const char* library_name) {
  api->library = dlopen(library_name, RTLD_NOW | RTLD_LOCAL);
  if (api->library == nullptr) return false;
  api->open = reinterpret_cast<OpenFn>(dlsym(api->library, "edu_backend_open"));
  api->start = reinterpret_cast<StartFn>(dlsym(api->library, "edu_backend_start_generation"));
  api->next_event = reinterpret_cast<NextEventFn>(dlsym(api->library, "edu_backend_next_event"));
  api->cancel = reinterpret_cast<CancelFn>(dlsym(api->library, "edu_backend_cancel_generation"));
  api->close = reinterpret_cast<CloseFn>(dlsym(api->library, "edu_backend_close"));
  if (api->open == nullptr || api->start == nullptr || api->next_event == nullptr ||
      api->cancel == nullptr || api->close == nullptr) {
    dlclose(api->library);
    *api = BackendApi{};
    return false;
  }
  return true;
}

std::string json_string_field(const std::string& json, const std::string& field);

const char* backend_library_from_config(const char* config_json) {
  if (config_json != nullptr && json_string_field(config_json, "backend") == "llamaCpp") {
    return "libedu_llama_cpp_backend.so";
  }
  return "libedu_litert_lm_backend.so";
}

std::string json_string_field(const std::string& json, const std::string& field) {
  const std::string marker = "\"" + field + "\"";
  const size_t key = json.find(marker);
  if (key == std::string::npos) return std::string();
  size_t value = json.find(':', key + marker.size());
  if (value == std::string::npos) return std::string();
  value = json.find_first_not_of(" \t\r\n", value + 1);
  if (value == std::string::npos || json[value] != '\"') return std::string();
  std::string output;
  bool escaped = false;
  for (size_t index = value + 1; index < json.size(); ++index) {
    const char character = json[index];
    if (escaped) {
      output.push_back(character);
      escaped = false;
    } else if (character == '\\') {
      escaped = true;
    } else if (character == '\"') {
      return output;
    } else {
      output.push_back(character);
    }
  }
  return std::string();
}

std::string escape_json_string(const std::string& value) {
  std::string escaped;
  for (const char character : value) {
    if (character == '\\' || character == '\"') escaped.push_back('\\');
    if (character == '\n') {
      escaped += "\\n";
    } else if (character == '\r') {
      escaped += "\\r";
    } else {
      escaped.push_back(character);
    }
  }
  return escaped;
}

void replace_json_string_field(std::string* json, const std::string& field,
                               const std::string& replacement) {
  const std::string marker = "\"" + field + "\"";
  const size_t key = json->find(marker);
  if (key == std::string::npos) return;
  const size_t colon = json->find(':', key + marker.size());
  if (colon == std::string::npos) return;
  const size_t value = json->find_first_not_of(" \t\r\n", colon + 1);
  if (value == std::string::npos || (*json)[value] != '\"') return;
  bool escaped = false;
  size_t end = value + 1;
  for (; end < json->size(); ++end) {
    if (escaped) {
      escaped = false;
    } else if ((*json)[end] == '\\') {
      escaped = true;
    } else if ((*json)[end] == '\"') {
      break;
    }
  }
  if (end >= json->size()) return;
  json->replace(value, end - value + 1, "\"" + escape_json_string(replacement) + "\"");
}

std::string llama_fallback_config(const char* config_json) {
  std::string config(config_json == nullptr ? "{}" : config_json);
  const std::string fallback = json_string_field(config, "llama_fallback_model_path");
  if (fallback.empty()) return std::string();
  replace_json_string_field(&config, "backend", "llamaCpp");
  replace_json_string_field(&config, "model_id", "gemma-4-e4b-gguf-fallback");
  replace_json_string_field(&config, "model_path", fallback);
  replace_json_string_field(&config, "quantization", "GGUF");
  return config;
}

RuntimeSession* from_handle(jlong handle) {
  return reinterpret_cast<RuntimeSession*>(static_cast<intptr_t>(handle));
}

jlong to_handle(RuntimeSession* session) {
  return static_cast<jlong>(reinterpret_cast<intptr_t>(session));
}
}  // namespace

extern "C" {
void* edu_runtime_open(const char* config_json) {
  BackendApi api;
  const bool requested_llama =
      std::strcmp(backend_library_from_config(config_json), "libedu_llama_cpp_backend.so") == 0;
  if (bind_backend(&api, backend_library_from_config(config_json))) {
    void* native_session = api.open(config_json);
    if (native_session != nullptr) return new RuntimeSession{api, native_session};
    dlclose(api.library);
  }

  if (!requested_llama) {
    const std::string fallback_config = llama_fallback_config(config_json);
    if (!fallback_config.empty() && bind_backend(&api, "libedu_llama_cpp_backend.so")) {
      void* fallback_session = api.open(fallback_config.c_str());
      if (fallback_session != nullptr) return new RuntimeSession{api, fallback_session};
      dlclose(api.library);
    }
  }
  return nullptr;
}

int64_t edu_runtime_start_generation(void* opaque, const char* request_json) {
  auto* session = static_cast<RuntimeSession*>(opaque);
  if (session == nullptr || request_json == nullptr) return -1;
  return session->api.start(session->backend_session, request_json);
}

char* edu_runtime_next_event(void* opaque, int64_t generation_id, int32_t timeout_ms) {
  auto* session = static_cast<RuntimeSession*>(opaque);
  if (session == nullptr) return nullptr;
  return session->api.next_event(session->backend_session, generation_id, timeout_ms);
}

int32_t edu_runtime_cancel_generation(void* opaque, int64_t generation_id) {
  auto* session = static_cast<RuntimeSession*>(opaque);
  if (session == nullptr) return -1;
  return session->api.cancel(session->backend_session, generation_id);
}

int32_t edu_runtime_backend_available(int32_t backend_index) {
  BackendApi api;
  const char* library_name = backend_index == 1
      ? "libedu_llama_cpp_backend.so"
      : "libedu_litert_lm_backend.so";
  if (!bind_backend(&api, library_name)) return 0;
  dlclose(api.library);
  return 1;
}

void edu_runtime_free_event(char* event_json) {
  std::free(event_json);
}

void edu_runtime_close(void* opaque) {
  auto* session = static_cast<RuntimeSession*>(opaque);
  if (session == nullptr) return;
  session->api.close(session->backend_session);
  dlclose(session->api.library);
  delete session;
}
}  // extern "C"

extern "C" JNIEXPORT jboolean JNICALL
Java_ai_lm7md_edu_NativeRuntimeJni_backendAvailable(JNIEnv*, jclass, jboolean use_llama) {
  return edu_runtime_backend_available(use_llama ? 1 : 0) == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlong JNICALL
Java_ai_lm7md_edu_NativeRuntimeJni_openModel(JNIEnv* env, jclass, jstring config_json) {
  const char* config = env->GetStringUTFChars(config_json, nullptr);
  if (config == nullptr) return 0;
  void* session = edu_runtime_open(config);
  env->ReleaseStringUTFChars(config_json, config);
  return to_handle(static_cast<RuntimeSession*>(session));
}

extern "C" JNIEXPORT jlong JNICALL
Java_ai_lm7md_edu_NativeRuntimeJni_startGeneration(
    JNIEnv* env, jclass, jlong handle, jstring request_json) {
  const char* request = env->GetStringUTFChars(request_json, nullptr);
  if (request == nullptr) return -1;
  const int64_t generation = edu_runtime_start_generation(from_handle(handle), request);
  env->ReleaseStringUTFChars(request_json, request);
  return static_cast<jlong>(generation);
}

extern "C" JNIEXPORT jstring JNICALL
Java_ai_lm7md_edu_NativeRuntimeJni_nextEvent(
    JNIEnv* env, jclass, jlong handle, jlong generation_id, jint timeout_ms) {
  char* event = edu_runtime_next_event(from_handle(handle), generation_id, timeout_ms);
  if (event == nullptr) return nullptr;
  jstring result = env->NewStringUTF(event);
  edu_runtime_free_event(event);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_ai_lm7md_edu_NativeRuntimeJni_cancelGeneration(
    JNIEnv*, jclass, jlong handle, jlong generation_id) {
  edu_runtime_cancel_generation(from_handle(handle), generation_id);
}

extern "C" JNIEXPORT void JNICALL
Java_ai_lm7md_edu_NativeRuntimeJni_closeModel(JNIEnv*, jclass, jlong handle) {
  edu_runtime_close(from_handle(handle));
}
