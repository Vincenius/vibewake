package com.vibewake.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarHost
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
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.vibewake.app.data.Connection
import com.vibewake.app.data.Machine
import com.vibewake.app.data.RelayState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachinesScreen(
    state: RelayState,
    snackbar: SnackbarHostState,
    pushHint: String?,
    onOpen: (Machine) -> Unit,
    onSetUpPush: () -> Unit,
    onUnpair: () -> Unit,
) {
    val now = rememberNow()
    var menu by remember { mutableStateOf(false) }
    var confirmUnpair by remember { mutableStateOf(false) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("VibeWake") },
                actions = {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, "Menu") }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem({ Text("Notifications…") }, onClick = { menu = false; onSetUpPush() })
                        DropdownMenuItem({ Text("Unpair this phone") }, onClick = { menu = false; confirmUnpair = true })
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { pad ->
        LazyColumn(
            Modifier.fillMaxSize().padding(pad),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { ConnectionBanner(state.connection) }
            pushHint?.let { item { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
            if (state.machines.isEmpty() && state.connection == Connection.Online) {
                item { Text("No Macs yet. Connect one in VibeWake on the Mac: Show Agents… → Phone app.") }
            }
            items(state.machines.values.sortedBy { it.name.lowercase() }, key = { it.id }) { m ->
                MachineCard(m, now) { onOpen(m) }
            }
        }
    }
    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text("Unpair this phone?") },
            text = { Text("You'll need a new pairing code from a Mac to connect again.") },
            confirmButton = { TextButton({ confirmUnpair = false; onUnpair() }) { Text("Unpair") } },
            dismissButton = { TextButton({ confirmUnpair = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun ConnectionBanner(c: Connection) {
    val text = when (c) {
        Connection.Online -> return
        Connection.Connecting -> "Connecting to the relay…"
        Connection.Offline -> "Not connected to the relay — retrying"
        Connection.Rejected -> "The relay no longer knows this phone. Unpair and pair again."
    }
    Text(text, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
}

@Composable
private fun MachineCard(m: Machine, now: Double, onClick: () -> Unit) {
    val dot = when {
        m.online -> Color(0xFF22C55E)
        m.sleeping -> Color(0xFF60A5FA)
        else -> Color(0xFF9CA3AF)
    }
    Card(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Laptop, null, Modifier.size(32.dp))
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(m.name, style = MaterialTheme.typography.titleMedium)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
                    Spacer(Modifier.width(6.dp))
                    Text(machineStatus(m, now), style = MaterialTheme.typography.bodySmall)
                }
            }
            m.snapshot?.battery?.let { b ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.BatteryStd, null, Modifier.size(16.dp))
                    Text("${b.percent}%${if (b.onBattery) "" else "⚡"}", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
