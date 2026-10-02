package com.vibewake.app.data

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

enum class Connection { Offline, Connecting, Online, Rejected }

data class RelayState(
    val connection: Connection = Connection.Offline,
    val machines: Map<String, Machine> = emptyMap(),
    /** Whether the relay has sent the machine list yet (until then, [machines] is just empty). */
    val machinesLoaded: Boolean = false,
    /** Recent commands by id (this phone's and others'). */
    val commands: Map<String, CommandRecord> = emptyMap(),
    /** Full replies fetched with "Load full reply", by session id. */
    val fullReplies: Map<String, FullReply> = emptyMap(),
)

/** A fetched full reply; [at] matches the snapshot's `reply.at` while it's still the latest one. */
data class FullReply(val text: String, val at: Double)

/**
 * The phone's connection to the relay (see protocol/PROTOCOL.md): a WebSocket while the app
 * is in the foreground, plus a few REST calls for pairing and push registration.
 */
class Relay(private val credentials: Credentials) {
    private val http = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .build()
    private val main = Handler(Looper.getMainLooper())
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow(RelayState())
    val state: StateFlow<RelayState> = _state

    /** One-line messages for a snackbar: failed commands, connection problems. */
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val messages: SharedFlow<String> = _messages

    private val _paired = MutableStateFlow(credentials.paired)
    /** Whether there's a device token; also set when pairing finishes after the screen that started it is gone. */
    val paired: StateFlow<Boolean> = _paired

    private var socket: WebSocket? = null
    private var wanted = false
    private var backoffMs = 1000L
    private val myRefs = mutableSetOf<String>()

    // MARK: - Connection

    /** Connect and stay connected (with backoff) until [stop]. */
    fun start() {
        wanted = true
        if (socket == null) connect()
    }

    fun stop() {
        wanted = false
        main.removeCallbacksAndMessages(null)
        socket?.close(1000, null)
        socket = null
        _state.update { it.copy(connection = Connection.Offline) }
    }

    private fun connect() {
        val server = credentials.server ?: return
        val token = credentials.token ?: return
        val url = server.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://") + "/ws/app"
        _state.update { it.copy(connection = Connection.Connecting) }
        val req = Request.Builder().url(url).header("Authorization", "Bearer $token").build()
        socket = http.newWebSocket(req, Listener())
    }

    private fun retry() {
        socket = null
        if (!wanted) return
        val delay = backoffMs
        backoffMs = (backoffMs * 2).coerceAtMost(30_000)
        main.postDelayed({ if (wanted && socket == null) connect() }, delay)
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            main.post {
                backoffMs = 1000
                _state.update { it.copy(connection = Connection.Online) }
            }
            // Retry a push endpoint the relay hasn't got yet.
            io.launch { runCatching { sendPendingPushEndpoint() } }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
            main.post {
                if (socket === webSocket) runCatching { handle(obj) }.onFailure { Log.w(TAG, "Bad message from the relay", it) }
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, null)
            main.post {
                if (socket !== webSocket) return@post
                if (code == 4001) {
                    // The relay doesn't know this phone any more (unpaired there).
                    socket = null
                    wanted = false
                    _state.update { it.copy(connection = Connection.Rejected) }
                } else {
                    _state.update { it.copy(connection = Connection.Offline) }
                    retry()
                }
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            main.post {
                if (socket !== webSocket) return@post
                _state.update { it.copy(connection = Connection.Offline) }
                retry()
            }
        }
    }

    private fun handle(obj: JsonObject) {
        when (obj["type"]?.jsonPrimitive?.content) {
            "machines" -> {
                // One machine the app can't read shouldn't hide the others.
                val list = obj["machines"]!!.jsonArray.mapNotNull { decode<Machine>(it) }
                _state.update { s -> s.copy(machines = list.associateBy { it.id }, machinesLoaded = true) }
            }
            "machine" -> {
                val m = json.decodeFromJsonElement<Machine>(obj["machine"]!!)
                _state.update { s -> s.copy(machines = s.machines + (m.id to m)) }
            }
            "commands" -> {
                val list = obj["commands"]!!.jsonArray.mapNotNull { decode<CommandRecord>(it) }
                _state.update { s -> s.copy(commands = list.associateBy { it.id }) }
            }
            "commandStatus" -> {
                val c = json.decodeFromJsonElement<CommandRecord>(obj["command"]!!)
                onCommand(c)
            }
            "error" -> obj["error"]?.jsonPrimitive?.content?.let { _messages.tryEmit(it) }
        }
    }

    private inline fun <reified T> decode(e: kotlinx.serialization.json.JsonElement): T? =
        runCatching { json.decodeFromJsonElement<T>(e) }.onFailure { Log.w(TAG, "Skipping unreadable ${T::class.simpleName}", it) }.getOrNull()

    private fun onCommand(c: CommandRecord) {
        _state.update { s ->
            var replies = s.fullReplies
            if (c.type == "fetchReply" && c.status == "done") {
                val result = c.result as? JsonObject
                val text = result?.get("text")?.jsonPrimitive?.content
                val at = result?.get("at")?.jsonPrimitive?.doubleOrNull ?: 0.0
                val sid = c.sessionId
                if (text != null && sid != null) replies = replies + (sid to FullReply(text, at))
            }
            // Keep the map from growing forever.
            val commands = (s.commands + (c.id to c)).values.sortedByDescending { it.createdAt }.take(200).associateBy { it.id }
            s.copy(commands = commands, fullReplies = replies)
        }
        if (c.ref != null && c.ref in myRefs && (c.status == "failed" || c.status == "expired")) {
            _messages.tryEmit("${describe(c.type)} failed: ${c.error ?: c.status}")
        }
    }

    private fun describe(type: String) = when (type) {
        "queueAdd" -> "Adding to the queue"
        "sendNow" -> "Sending"
        "newSession" -> "Starting the chat"
        "askStatus" -> "Asking for status"
        "continue" -> "Continue"
        "fetchReply" -> "Loading the reply"
        else -> type
    }

    // MARK: - Commands

    /** Send a command to a Mac; returns its ref (to follow its status), or null when offline. */
    fun send(machineId: String, cmd: JsonObject): String? {
        val ws = socket
        if (ws == null || _state.value.connection != Connection.Online) {
            _messages.tryEmit("Not connected to the relay")
            return null
        }
        val ref = UUID.randomUUID().toString()
        myRefs += ref
        val msg = buildJsonObject {
            put("type", "command")
            put("ref", ref)
            put("machineId", machineId)
            put("cmd", cmd)
        }
        if (!ws.send(msg.toString())) {
            myRefs -= ref
            _messages.tryEmit("Not connected to the relay")
            return null
        }
        // The relay echoes the ref in a commandStatus; without one, the command never arrived.
        main.postDelayed({
            if (ref in myRefs && _state.value.commands.values.none { it.ref == ref }) {
                onCommand(CommandRecord(
                    id = "local-$ref", ref = ref, machineId = machineId, cmd = cmd, status = "failed",
                    error = "the relay didn't answer", createdAt = System.currentTimeMillis() / 1000.0,
                ))
            }
        }, ACK_TIMEOUT_MS)
        return ref
    }

    fun command(type: String, vararg fields: Pair<String, Any?>): JsonObject = buildJsonObject {
        put("type", type)
        for ((k, v) in fields) when (v) {
            null -> {}
            is String -> put(k, v)
            is Int -> put(k, v)
            is Boolean -> put(k, v)
            else -> put(k, JsonPrimitive(v.toString()))
        }
    }

    // MARK: - REST

    /** [code]: the HTTP status, 0 when the relay wasn't reached. */
    class RelayException(message: String, val code: Int = 0) : IOException(message)

    /** Trade a pairing code (from the Mac's QR code) for a device token. */
    suspend fun pair(server: String, code: String) = withContext(Dispatchers.IO) {
        val base = server.trim().trimEnd('/')
        require(base.startsWith("https://") || base.startsWith("http://")) { "The server address must start with https://" }
        val body = buildJsonObject {
            put("code", code.trim().uppercase())
            put("name", "${Build.MANUFACTURER} ${Build.MODEL}")
        }
        val obj = post("$base/api/device/register", body, null)
        val token = obj["token"]?.jsonPrimitive?.content ?: throw RelayException("The relay sent no token")
        // Saved right away (no suspension point), so the code isn't lost if the caller was cancelled meanwhile.
        credentials.save(base, token)
        _paired.value = true
        // The socket is only touched on the main thread.
        main.post {
            stop()
            start()
        }
    }

    /** Tell the relay where to push notifications (null: stop pushing); retried on reconnect if it fails. */
    suspend fun setPushEndpoint(endpoint: String?) = withContext(Dispatchers.IO) {
        if (!credentials.paired) return@withContext
        credentials.pendingPushEndpoint = endpoint ?: ""
        sendPendingPushEndpoint()
    }

    private fun sendPendingPushEndpoint() {
        val pending = credentials.pendingPushEndpoint ?: return
        val server = credentials.server ?: return
        val token = credentials.token ?: return
        val endpoint = pending.ifEmpty { null }
        if (endpoint != credentials.pushEndpoint) {
            val body = buildJsonObject { put("endpoint", endpoint) }
            try {
                post("$server/api/device/push", body, token)
            } catch (e: RelayException) {
                // A 4xx is final (e.g. an endpoint the relay won't push to): don't retry it. Network errors and 5xx are.
                if (e.code in 400..499 && credentials.pendingPushEndpoint == pending) credentials.pendingPushEndpoint = null
                throw e
            }
            credentials.pushEndpoint = endpoint
        }
        if (credentials.pendingPushEndpoint == pending) credentials.pendingPushEndpoint = null
    }

    fun unpair() {
        val server = credentials.server
        val token = credentials.token
        stop()
        credentials.clear()
        _paired.value = false
        _state.value = RelayState()
        // Revoke the token (and push endpoint) on the relay; best effort.
        if (server != null && token != null) {
            io.launch { runCatching { execute(Request.Builder().url("$server/api/device").delete().header("Authorization", "Bearer $token").build()) } }
        }
    }

    private fun post(url: String, body: JsonObject, token: String?): JsonObject {
        val req = Request.Builder().url(url)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .apply { if (token != null) header("Authorization", "Bearer $token") }
            .build()
        return execute(req)
    }

    private fun execute(req: Request): JsonObject {
        http.newCall(req).execute().use { res ->
            val text = res.body?.string().orEmpty()
            val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            if (!res.isSuccessful) {
                val error = obj?.get("error")?.jsonPrimitive?.content ?: "HTTP ${res.code}"
                throw RelayException(error, res.code)
            }
            return obj ?: JsonObject(emptyMap())
        }
    }

    companion object {
        private const val TAG = "Relay"
        private const val ACK_TIMEOUT_MS = 30_000L
    }
}
