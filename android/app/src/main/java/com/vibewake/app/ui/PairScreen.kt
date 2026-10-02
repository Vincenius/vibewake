package com.vibewake.app.ui

import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.vibewake.app.data.Relay
import kotlinx.coroutines.launch
import androidx.activity.compose.rememberLauncherForActivityResult

/** Parse `vibewake://pair?server=…&code=…`. */
fun parsePairLink(link: String): Pair<String, String>? {
    val uri = runCatching { Uri.parse(link) }.getOrNull() ?: return null
    if (uri.scheme != "vibewake" || uri.host != "pair") return null
    val server = uri.getQueryParameter("server") ?: return null
    val code = uri.getQueryParameter("code") ?: return null
    return server to code
}

@Composable
fun PairScreen(relay: Relay, link: String?, onPaired: () -> Unit) {
    var server by remember { mutableStateOf("https://") }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun pair(s: String, c: String) {
        busy = true
        error = null
        scope.launch {
            try {
                relay.pair(s, c)
                onPaired()
            } catch (e: Exception) {
                error = e.message ?: e.toString()
            } finally {
                busy = false
            }
        }
    }

    // Opened from a scanned QR code (system camera) or a link.
    LaunchedEffect(link) {
        parsePairLink(link ?: return@LaunchedEffect)?.let { (s, c) -> server = s; code = c; pair(s, c) }
    }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        val parsed = result.contents?.let(::parsePairLink)
        if (parsed != null) {
            server = parsed.first
            code = parsed.second
            pair(parsed.first, parsed.second)
        } else if (result.contents != null) {
            error = "That isn't a VibeWake pairing code"
        }
    }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(24.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Pair with your Mac", style = MaterialTheme.typography.headlineSmall)
            Text(
                "On your Mac, open VibeWake → Show Agents… → Phone app → Pair Phone…, then scan the code.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Button(
                onClick = {
                    scanner.launch(
                        ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the code shown on your Mac")
                            .setBeepEnabled(false).setOrientationLocked(false),
                    )
                },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.QrCodeScanner, null)
                Text("  Scan QR code")
            }
            Text("Or enter it by hand", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                server, { server = it }, label = { Text("Relay server") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                code, { code = it }, label = { Text("Pairing code") }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters), modifier = Modifier.fillMaxWidth(),
            )
            OutlinedButton(onClick = { pair(server, code) }, enabled = !busy && code.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
                if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text("Pair")
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}
