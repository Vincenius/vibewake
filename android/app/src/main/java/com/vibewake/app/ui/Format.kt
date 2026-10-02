package com.vibewake.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.vibewake.app.data.Machine
import com.vibewake.app.data.Session
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

fun nowSeconds() = System.currentTimeMillis() / 1000.0

/** The current time, refreshed every 15 s, so "working 3m" labels tick along. */
@Composable
fun rememberNow(): Double {
    var now by remember { mutableDoubleStateOf(nowSeconds()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(15_000)
            now = nowSeconds()
        }
    }
    return now
}

fun elapsed(since: Double, now: Double): String {
    val s = (now - since).toLong().coerceAtLeast(0)
    return when {
        s < 60 -> "${s}s"
        s < 3600 -> "${s / 60}m"
        s < 86400 -> "${s / 3600}h ${s % 3600 / 60}m"
        else -> "${s / 86400}d"
    }
}

fun clock(t: Double): String {
    val date = Date((t * 1000).toLong())
    val today = DateFormat.getDateInstance(DateFormat.SHORT).format(date) == DateFormat.getDateInstance(DateFormat.SHORT).format(Date())
    return if (today) DateFormat.getTimeInstance(DateFormat.SHORT).format(date)
    else DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(date)
}

fun stateText(s: Session, now: Double): String {
    val since = s.stateSince?.let { " " + elapsed(it, now) } ?: ""
    return when (s.state) {
        "working" -> "working$since"
        "idle" -> "idle$since"
        "limited" -> s.limitedUntil?.let { if (it > now) "usage limit until ${clock(it)}" else "usage limit lifted" } ?: "usage limit"
        "stalled" -> "silent for${since.ifEmpty { " a while" }}"
        "waiting" -> "waiting for your input$since"
        "finished" -> s.stateSince?.let { "finished ${elapsed(it, now)} ago" } ?: "finished"
        "failed" -> "failed"
        else -> s.state
    }
}

fun machineStatus(m: Machine, now: Double): String = when {
    m.online -> {
        val sessions = m.snapshot?.sessions.orEmpty()
        val working = sessions.count { it.state == "working" || it.state == "stalled" || it.state == "waiting" }
        val parts = mutableListOf("Online")
        if (working > 0) parts += "$working working"
        if (sessions.size - working > 0) parts += "${sessions.size - working} idle"
        if (m.snapshot?.paused == true) parts += "paused"
        parts.joinToString(" · ")
    }
    m.sleeping && m.nextWakeAt != null ->
        if (m.nextWakeAt > now) "Asleep · checks in at ${clock(m.nextWakeAt)}" else "Asleep · check-in due"
    m.sleeping -> "Asleep · won't wake on its own"
    m.lastSeen > 0 -> "Offline · last seen ${elapsed(m.lastSeen, now)} ago"
    else -> "Never connected"
}
