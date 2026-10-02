package com.vibewake.app.data

import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
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
    /** Recent commands by id (this phone's and others'). */
    val commands: Map<String, CommandRecord> = emptyMap(),
    /** Full replies fetched with "Load full reply", by session id. */
    val fullReplies: Map<String, String> = emptyMap(),
)

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

    private val _state = MutableStateFlow(RelayState())
    val state: StateFlow<RelayState> = _state

    /** One-line messages for a snackbar: failed commands, connection problems. */
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val messages: SharedFlow<String> = _messages

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
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
            main.post { if (socket === webSocket) handle(obj) }
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
                val list = obj["machines"]!!.jsonArray.map { json.decodeFromJsonElement<Machine>(it) }
                _state.update { s -> s.copy(machines = list.associateBy { it.id }) }
            }
            "machine" -> {
                val m = json.decodeFromJsonElement<Machine>(obj["machine"]!!)
                _state.update { s -> s.copy(machines = s.machines + (m.id to m)) }
            }
            "commands" -> {
                val list = obj["commands"]!!.jsonArray.map { json.decodeFromJsonElement<CommandRecord>(it) }
                _state.update { s -> s.copy(commands = list.associateBy { it.id }) }
            }
            "commandStatus" -> {
                val c = json.decodeFromJsonElement<CommandRecord>(obj["command"]!!)
                onCommand(c)
            }
            "error" -> obj["error"]?.jsonPrimitive?.content?.let { _messages.tryEmit(it) }
        }
    }

    private fun onCommand(c: CommandRecord) {
        _state.update { s ->
            var replies = s.fullReplies
            if (c.type == "fetchReply" && c.status == "done") {
                val text = (c.result as? JsonObject)?.get("text")?.jsonPrimitive?.content
                val sid = c.sessionId
                if (text != null && sid != null) replies = replies + (sid to text)
            }
            // Keep the map from growing forever.
            val commands = (s.commands + (c.id to c)).values.sortedByDescending { it.createdAt }.take(200).associateBy { it.id }
            s.copy(commands = commands, fullReplies = replies)
        }
        if (c.ref != null && c.ref in myRefs && (c.status == "failed" || c.status == "expired")) {
            _messages.tryEmit("${describe(c)} failed: ${c.error ?: c.status}")
        }
    }

    private fun describe(c: CommandRecord) = when (c.type) {
        "queueAdd" -> "Adding to the queue"
        "sendNow" -> "Sending"
        "newSession" -> "Starting the chat"
        "askStatus" -> "Asking for status"
        "continue" -> "Continue"
        "fetchReply" -> "Loading the reply"
        else -> c.type
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
        ws.send(msg.toString())
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

    class RelayException(message: String) : IOException(message)

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
        stop()
        credentials.save(base, token)
        start()
    }

    /** Tell the relay where to push notifications (null: stop pushing). */
    suspend fun setPushEndpoint(endpoint: String?) = withContext(Dispatchers.IO) {
        val server = credentials.server ?: return@withContext
        if (endpoint == credentials.pushEndpoint) return@withContext
        val body = buildJsonObject { put("endpoint", endpoint) }
        post("$server/api/device/push", body, credentials.token)
        credentials.pushEndpoint = endpoint
    }

    fun unpair() {
        stop()
        credentials.clear()
        _state.value = RelayState()
    }

    private fun post(url: String, body: JsonObject, token: String?): JsonObject {
        val req = Request.Builder().url(url)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .apply { if (token != null) header("Authorization", "Bearer $token") }
            .build()
        http.newCall(req).execute().use { res ->
            val text = res.body?.string().orEmpty()
            val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            if (!res.isSuccessful) {
                val error = obj?.get("error")?.jsonPrimitive?.content ?: "HTTP ${res.code}"
                throw RelayException(error)
            }
            return obj ?: JsonObject(emptyMap())
        }
    }
}
