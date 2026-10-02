package com.vibewake.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
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
import com.vibewake.app.data.Relay
import com.vibewake.app.data.RelayState
import com.vibewake.app.data.Session

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachineScreen(
    relay: Relay,
    state: RelayState,
    machineId: String,
    snackbar: SnackbarHostState,
    onBack: () -> Unit,
    onOpen: (Session) -> Unit,
) {
    val m = state.machines[machineId]
    val now = rememberNow()
    var newPrompt by remember { mutableStateOf(false) }
    val snap = m?.snapshot
    val canControl = snap?.remoteControl != false

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(m?.name ?: "Mac", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    if (snap != null) {
                        // Pause = the Mac follows normal sleep rules (as in the menu bar).
                        IconButton(onClick = { relay.send(machineId, relay.command("setPaused", "paused" to !snap.paused)) }) {
                            Icon(if (snap.paused) Icons.Default.PlayArrow else Icons.Default.Pause, if (snap.paused) "Resume" else "Pause")
                        }
                    }
                },
            )
        },
        floatingActionButton = {
            if (canControl && snap?.projects?.isNotEmpty() == true) {
                ExtendedFloatingActionButton(onClick = { newPrompt = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text("New prompt") })
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { pad ->
        LazyColumn(Modifier.fillMaxSize().padding(pad), contentPadding = PaddingValues(bottom = 88.dp)) {
            item { ConnectionBanner(state.connection) }
            if (m != null) item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(machineStatus(m, now), style = MaterialTheme.typography.bodyMedium)
                    if (!m.online) Text(
                        "Prompts and changes you make now run when it next connects.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (!canControl) Text(
                        "Remote control is turned off on this Mac — you can watch, not act.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                    )
                }
            }
            val groups = snap?.sessions.orEmpty().groupBy { it.project ?: it.agent }.toSortedMap(String.CASE_INSENSITIVE_ORDER)
            if (groups.isEmpty()) item {
                Text("No chats.", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            for ((project, sessions) in groups) {
                item(key = "h-$project") {
                    Text(project, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
                }
                items(sessions, key = { it.id }) { s -> SessionRow(s, now) { onOpen(s) } }
            }
        }
    }

    if (newPrompt && snap != null) {
        NewPromptDialog(
            projects = snap.projects,
            note = when {
                m.online -> null
                m.sleeping && m.nextWakeAt != null -> "The Mac is asleep. It runs this when it checks in at ${clock(m.nextWakeAt)}."
                else -> "The Mac is offline. It runs this when it reconnects."
            },
            onDismiss = { newPrompt = false },
            onSend = { cwd, prompt ->
                relay.send(machineId, relay.command("newSession", "cwd" to cwd, "prompt" to prompt))
                newPrompt = false
            },
        )
    }
}

@Composable
private fun SessionRow(s: Session, now: Double, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        leadingContent = { Box(Modifier.size(10.dp).clip(CircleShape).background(stateColor(s.state))) },
        headlineContent = { Text(s.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column {
                val extra = buildList {
                    if (s.subagents > 0) add("${s.subagents} subagent${if (s.subagents == 1) "" else "s"}")
                    if (s.headless) add("headless")
                }
                Text((listOf(stateText(s, now)) + extra).joinToString(" · "), style = MaterialTheme.typography.bodySmall)
                (s.blocked ?: s.next)?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        },
        trailingContent = { if (s.queue.isNotEmpty()) Badge { Text("${s.queue.size}") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewPromptDialog(projects: List<String>, note: String?, onDismiss: () -> Unit, onSend: (String, String) -> Unit) {
    var cwd by remember { mutableStateOf(projects.first()) }
    var prompt by remember { mutableStateOf("") }
    var open by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("New chat") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                ExposedDropdownMenuBox(open, { open = it }) {
                    OutlinedTextField(
                        cwd.substringAfterLast('/'), {}, readOnly = true, label = { Text("Project") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
                        modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
                    )
                    ExposedDropdownMenu(open, { open = false }) {
                        for (p in projects) DropdownMenuItem(
                            text = { Column { Text(p.substringAfterLast('/')); Text(p, style = MaterialTheme.typography.bodySmall) } },
                            onClick = { cwd = p; open = false },
                        )
                    }
                }
                OutlinedTextField(prompt, { prompt = it }, label = { Text("Prompt") }, minLines = 4, modifier = Modifier.fillMaxWidth().heightIn(max = 280.dp))
                Text(
                    "Opens a new chat in the editor if someone is at the Mac; otherwise it runs headless and you can follow up from here.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary) }
            }
        },
        confirmButton = { TextButton({ onSend(cwd, prompt.trim()) }, enabled = prompt.isNotBlank()) { Text("Start") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}
