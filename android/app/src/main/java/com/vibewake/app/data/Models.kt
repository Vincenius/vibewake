package com.vibewake.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Mirrors protocol/PROTOCOL.md. Times are epoch seconds. */

val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; explicitNulls = false; encodeDefaults = true }

@Serializable
data class Machine(
    val id: String,
    val name: String,
    val model: String = "",
    val online: Boolean = false,
    val lastSeen: Double = 0.0,
    val sleeping: Boolean = false,
    val nextWakeAt: Double? = null,
    val snapshot: Snapshot? = null,
)

@Serializable
data class Battery(val onBattery: Boolean, val percent: Int)

@Serializable
data class Snapshot(
    val at: Double = 0.0,
    val paused: Boolean = false,
    val remoteControl: Boolean = true,
    val lidClosed: Boolean = false,
    val battery: Battery? = null,
    val nobodyAtScreen: Boolean = false,
    val wakeIntervalMinutes: Double = 0.0,
    val projects: List<String> = emptyList(),
    val sessions: List<Session> = emptyList(),
)

@Serializable
data class QueueItem(val id: String, val text: String, val mode: String = "sameChat", val createdAt: Double = 0.0)

@Serializable
data class Reply(val text: String, val at: Double = 0.0, val truncated: Boolean = false)

@Serializable
data class Session(
    val id: String,
    val agent: String = "claude",
    val session: String = "",
    val project: String? = null,
    val cwd: String? = null,
    val title: String = "",
    val state: String = "idle",
    val stateSince: Double? = null,
    val limitedUntil: Double? = null,
    val subagents: Int = 0,
    val canReceive: Boolean = false,
    val headless: Boolean = false,
    val blocked: String? = null,
    val next: String? = null,
    val queue: List<QueueItem> = emptyList(),
    val reply: Reply? = null,
)

@Serializable
data class CommandRecord(
    val id: String,
    val ref: String? = null,
    val machineId: String,
    val cmd: JsonObject,
    val status: String,
    val error: String? = null,
    val result: JsonElement? = null,
    val createdAt: Double = 0.0,
    val updatedAt: Double = 0.0,
) {
    val open get() = status == "pending" || status == "delivered"
    val type get() = (cmd["type"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: ""
    val sessionId get() = (cmd["sessionId"] as? kotlinx.serialization.json.JsonPrimitive)?.content
}

/** What the relay pushes through UnifiedPush. */
@Serializable
data class PushPayload(
    val machineId: String,
    val machineName: String = "",
    val sessionId: String = "",
    val kind: String,
    val title: String = "",
    val text: String = "",
)
