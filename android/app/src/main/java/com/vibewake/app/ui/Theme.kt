package com.vibewake.app.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val Green = Color(0xFF22A355)

@Composable
fun VibeWakeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val ctx = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        dark -> darkColorScheme(primary = Color(0xFF4ADE80))
        else -> lightColorScheme(primary = Green)
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/** Same colors as the Mac's Agents window. */
fun stateColor(state: String): Color = when (state) {
    "working" -> Color(0xFF22C55E)
    "limited" -> Color(0xFFA855F7)
    "stalled" -> Color(0xFFF97316)
    "waiting" -> Color(0xFFEAB308)
    "failed" -> Color(0xFFEF4444)
    else -> Color(0xFF9CA3AF)
}
