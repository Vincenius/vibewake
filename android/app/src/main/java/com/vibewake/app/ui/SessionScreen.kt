package com.vibewake.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vibewake.app.data.Connection
import com.vibewake.app.data.QueueItem
import com.vibewake.app.data.Relay
import com.vibewake.app.data.RelayState
import com.vibewake.app.data.Session

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SessionScreen(
    relay: Relay,
    state: RelayState,
    machineId: String,
    sessionId: String,
    snackbar: SnackbarHostState,
    onBack: () -> Unit,
) {
    val machine = state.machines[machineId]
    val s = machine?.snapshot?.sessions?.firstOrNull { it.id == sessionId }
    val now = rememberNow()
    val canControl = machine?.snapshot?.remoteControl != false
    val busy = state.commands.values.any { it.open && it.machineId == machineId && it.sessionId == sessionId }
    var editing by remember { mutableStateOf<QueueItem?>(null) }

    /** Returns whether the command went out (false: offline, keep what the user typed). */
    fun send(type: String, vararg fields: Pair<String, Any?>): Boolean =
        relay.send(machineId, relay.command(type, "sessionId" to sessionId, *fields)) != null

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(s?.title ?: "Chat", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).imePadding()) {
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth()) // waiting for the Mac to confirm
            if (s == null) {
                // Before the first machine list (or snapshot) arrives, the chat isn't known either way.
                val loading = !state.machinesLoaded || (machine != null && machine.snapshot == null && machine.online)
                val connecting = state.connection == Connection.Connecting || state.connection == Connection.Online
                if (loading && connecting) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        Text("Connecting…")
                    }
                } else {
                    Text(
                        when {
                            !state.machinesLoaded -> "Not connected to the relay."
                            machine?.online == false -> "The Mac is not connected."
                            else -> "This chat is closed."
                        },
                        Modifier.padding(16.dp),
                    )
                }
                return@Column
            }
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Header(s, now)
                if (canControl) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!s.headless || s.state == "working") AssistChip({ send("askStatus") }, { Text("Ask for status") }, enabled = s.canReceive || s.headless)
                    AssistChip({ send("continue") }, { Text("Continue") }, enabled = s.canReceive || s.headless)
                    if (s.blocked != null) AssistChip({ send("resumeQueue") }, { Text("Resume autopilot") })
                }

                // A full reply fetched earlier only counts while it's still the latest one.
                val full = state.fullReplies[sessionId]?.takeIf { it.at == s.reply?.at }?.text
                ReplyCard(s, full) { send("fetchReply") }

                Text("Queue", style = MaterialTheme.typography.titleMedium)
                if (s.queue.isEmpty()) {
                    Text(
                        "Nothing queued. Queued prompts run one by one each time this chat finishes a turn.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                s.queue.forEachIndexed { i, item ->
                    QueueRow(
                        item, i, s.queue.size, canControl,
                        onMove = { by -> send("queueMove", "itemId" to item.id, "by" to by) },
                        onEdit = { editing = item },
                        onDelete = { send("queueRemove", "itemId" to item.id) },
                    )
                }
            }
            if (canControl) {
                HorizontalDivider()
                Composer(s) { text, mode, now ->
                    if (now) send("sendNow", "text" to text) else send("queueAdd", "text" to text, "mode" to mode)
                }
            }
        }
    }

    editing?.let { item ->
        EditDialog(item, onDismiss = { editing = null }) { text, mode ->
            if (send("queueEdit", "itemId" to item.id, "text" to text, "mode" to mode)) editing = null
        }
    }
}

@Composable
private fun Header(s: Session, now: Double) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        s.cwd?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).clip(CircleShape).background(stateColor(s.state)))
            Spacer(Modifier.width(8.dp))
            Text(stateText(s, now) + if (s.subagents > 0) " · ${s.subagents} subagents" else "", style = MaterialTheme.typography.bodyLarge)
        }
        s.next?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary) }
        s.blocked?.let { Text("Paused: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        if (s.headless) Text(
            "Runs headless on the Mac (claude -p); each prompt continues the same chat. It's also listed in the editor's past conversations.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!s.canReceive && !s.headless) Text(
            if (s.agent == "claude") "This chat can't receive prompts yet (no inbox socket). Restart it after updating VibeWake's hooks."
            else "${s.agent} chats are shown for reference only.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ReplyCard(s: Session, full: String?, onLoadFull: () -> Unit) {
    val reply = s.reply
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                if (reply != null && reply.at > 0) "Last reply · ${clock(reply.at)}" else "Last reply",
                style = MaterialTheme.typography.labelLarge,
            )
            if (reply == null) {
                Text("No reply yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Markdown(full ?: reply.text)
                if (reply.truncated && full == null) TextButton(onLoadFull) { Text("Load the full reply") }
            }
        }
    }
}

@Composable
private fun QueueRow(
    item: QueueItem, index: Int, count: Int, canControl: Boolean,
    onMove: (Int) -> Unit, onEdit: () -> Unit, onDelete: () -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 12.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("${index + 1}.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(item.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                Text(if (item.mode == "newChat") "new chat" else "same chat", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (canControl) {
                IconButton({ onMove(-1) }, enabled = index > 0) { Icon(Icons.Default.KeyboardArrowUp, "Move up") }
                IconButton({ onMove(1) }, enabled = index < count - 1) { Icon(Icons.Default.KeyboardArrowDown, "Move down") }
                IconButton(onEdit) { Icon(Icons.Default.Edit, "Edit") }
                IconButton(onDelete) { Icon(Icons.Default.Delete, "Delete") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModePicker(mode: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    SingleChoiceSegmentedButtonRow(modifier) {
        SegmentedButton(mode == "sameChat", { onChange("sameChat") }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Same chat") }
        SegmentedButton(mode == "newChat", { onChange("newChat") }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("New chat") }
    }
}

@Composable
private fun Composer(s: Session, onSend: (text: String, mode: String, now: Boolean) -> Boolean) {
    var text by remember(s.id) { mutableStateOf("") }
    var mode by remember(s.id) { mutableStateOf("sameChat") }
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(text, { text = it }, placeholder = { Text("Prompt") }, modifier = Modifier.fillMaxWidth().heightIn(max = 160.dp))
        ModePicker(mode, { mode = it }, Modifier.fillMaxWidth())
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
            OutlinedButton(
                { if (onSend(text.trim(), mode, true)) text = "" },
                enabled = text.isNotBlank() && mode == "sameChat" && (s.canReceive || s.headless),
            ) { Text("Send now") }
            Button({ if (onSend(text.trim(), mode, false)) text = "" }, enabled = text.isNotBlank()) { Text("Queue") }
        }
    }
}

@Composable
private fun EditDialog(item: QueueItem, onDismiss: () -> Unit, onSave: (String, String) -> Unit) {
    var text by remember { mutableStateOf(item.text) }
    var mode by remember { mutableStateOf(item.mode) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit queued prompt") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(text, { text = it }, minLines = 3, modifier = Modifier.fillMaxWidth().heightIn(max = 280.dp))
                ModePicker(mode, { mode = it })
            }
        },
        confirmButton = { TextButton({ onSave(text.trim(), mode) }, enabled = text.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}
