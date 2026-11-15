package ai.lm7md.edu

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Android MethodChannel façade for the JNI/C-ABI runtime dispatcher. */
class EduNativeRuntimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val sessions = ConcurrentHashMap<String, RuntimeSession>()
    private var methods: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "edu/native_runtime").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isBackendAvailable" -> {
                    val backend = call.argument<String>("backend")
                        ?: throw IllegalArgumentException("Missing backend name.")
                    result.success(NativeRuntimeJni.backendAvailable(backend == "llamaCpp"))
                }
                "openModel" -> openModel(call, result)
                "startGeneration" -> startGeneration(call, result)
                "pollEvent" -> pollEvent(call, result)
                "cancelGeneration" -> cancelGeneration(call, result)
                "closeModel" -> closeModel(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("native_runtime", error.message ?: "Native runtime operation failed.", null)
        }
    }

    private fun openModel(call: MethodCall, result: MethodChannel.Result) {
        val config = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("Model configuration is missing.")
        val sessionHandle = NativeRuntimeJni.openModel(JSONObject(config).toString())
        if (sessionHandle == 0L) {
            throw IllegalStateException("No compatible LiteRT-LM or llama.cpp backend is packaged.")
        }
        val sessionId = UUID.randomUUID().toString()
        sessions[sessionId] = RuntimeSession(sessionHandle)
        result.success(sessionId)
    }

    private fun startGeneration(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("Generation arguments are missing.")
        val sessionId = args["session_id"] as? String
            ?: throw IllegalArgumentException("Missing model session id.")
        val generationId = args["generation_id"] as? String
            ?: throw IllegalArgumentException("Missing generation id.")
        val requestId = args["request_id"] as? String
            ?: throw IllegalArgumentException("Missing request id.")
        val session = sessions[sessionId]
            ?: throw IllegalStateException("Native model session is not open.")
        val jobId = NativeRuntimeJni.startGeneration(session.handle, JSONObject(args).toString())
        if (jobId < 0L) throw IllegalStateException("Native runtime rejected generation.")
        session.jobs[requestId] = ActiveGeneration(jobId, generationId)
        result.success(null)
    }

    private fun pollEvent(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("Poll arguments are missing.")
        val sessionId = args["session_id"] as? String
            ?: throw IllegalArgumentException("Missing model session id.")
        val requestId = args["request_id"] as? String
            ?: throw IllegalArgumentException("Missing request id.")
        val generationId = args["generation_id"] as? String
            ?: throw IllegalArgumentException("Missing generation id.")
        val timeoutMs = ((args["timeout_ms"] as? Number)?.toInt() ?: 100).coerceIn(1, 500)
        val session = sessions[sessionId]
            ?: throw IllegalStateException("Native model session is not open.")
        val generation = session.jobs[requestId]
            ?: throw IllegalStateException("Native generation is not active.")
        if (generation.generationId != generationId) {
            throw IllegalArgumentException("Generation id does not match the active request.")
        }
        if (!generation.polling.compareAndSet(false, true)) {
            throw IllegalStateException("A poll is already active for this generation.")
        }
        val future = executor.submit {
            try {
                val eventJson = NativeRuntimeJni.nextEvent(session.handle, generation.jobId, timeoutMs)
                if (eventJson == null) {
                    mainHandler.post { result.success(null) }
                } else {
                    val event = JSONObject(eventJson)
                    event.put("session_id", sessionId)
                    event.put("generation_id", generationId)
                    if (!event.has("request_id")) event.put("request_id", requestId)
                    val type = event.optString("type")
                    if (type == "completed" || type == "failed") {
                        session.jobs.remove(requestId, generation)
                    }
                    mainHandler.post { result.success(jsonObjectToMap(event)) }
                }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error("native_runtime_poll", error.message ?: "Native event polling failed.", null)
                }
            } finally {
                generation.polling.set(false)
            }
        }
        generation.pollFuture = future
    }

    private fun cancelGeneration(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("Cancellation arguments are missing.")
        val sessionId = args["session_id"] as? String
            ?: throw IllegalArgumentException("Missing model session id.")
        val requestId = args["request_id"] as? String
            ?: throw IllegalArgumentException("Missing request id.")
        val session = sessions[sessionId]
        val generation = session?.jobs?.get(requestId)
        if (session != null && generation != null) {
            NativeRuntimeJni.cancelGeneration(session.handle, generation.jobId)
        }
        result.success(null)
    }

    private fun closeModel(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = (call.arguments as? Map<*, *>)?.get("session_id") as? String
            ?: throw IllegalArgumentException("Missing model session id.")
        val session = sessions.remove(sessionId)
        if (session == null) {
            result.success(null)
            return
        }
        val activeJobs = session.jobs.values.toList()
        activeJobs.forEach { NativeRuntimeJni.cancelGeneration(session.handle, it.jobId) }
        executor.submit {
            activeJobs.forEach { generation ->
                try {
                    generation.pollFuture?.get(5, TimeUnit.SECONDS)
                } catch (_: Throwable) {
                    // Cancellation has been issued; teardown proceeds after bounded poll wait.
                }
            }
            NativeRuntimeJni.closeModel(session.handle)
            mainHandler.post { result.success(null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        val closingSessions = sessions.values.toList()
        closingSessions.forEach { session ->
            session.jobs.values.forEach { NativeRuntimeJni.cancelGeneration(session.handle, it.jobId) }
        }
        sessions.clear()
        executor.shutdown()
        Thread {
            closingSessions.forEach { session ->
                session.jobs.values.forEach { generation ->
                    try {
                        generation.pollFuture?.get(5, TimeUnit.SECONDS)
                    } catch (_: Throwable) {
                        // Native cancellation has been issued and plugin teardown must continue.
                    }
                }
                NativeRuntimeJni.closeModel(session.handle)
            }
            executor.shutdownNow()
        }.start()
        methods = null
    }

    private data class RuntimeSession(val handle: Long) {
        val jobs = ConcurrentHashMap<String, ActiveGeneration>()
    }

    private data class ActiveGeneration(
        val jobId: Long,
        val generationId: String,
        val polling: AtomicBoolean = AtomicBoolean(false),
        @Volatile var pollFuture: Future<*>? = null,
    )

    private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = jsonValue(json.get(key))
        }
        return result
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
        else -> value
    }
}

/** JNI entry points are implemented by the C++ C-ABI dispatcher. */
internal object NativeRuntimeJni {
    init {
        System.loadLibrary("edu_tutor_runtime")
    }

    @JvmStatic external fun backendAvailable(useLlamaCpp: Boolean): Boolean
    @JvmStatic external fun openModel(configJson: String): Long
    @JvmStatic external fun startGeneration(handle: Long, requestJson: String): Long
    @JvmStatic external fun nextEvent(handle: Long, generationId: Long, timeoutMs: Int): String?
    @JvmStatic external fun cancelGeneration(handle: Long, generationId: Long)
    @JvmStatic external fun closeModel(handle: Long)
}
