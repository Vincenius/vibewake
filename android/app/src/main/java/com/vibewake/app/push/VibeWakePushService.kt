package com.vibewake.app.push

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import com.vibewake.app.MainActivity
import com.vibewake.app.R
import com.vibewake.app.VibeWakeApp
import com.vibewake.app.data.PushPayload
import com.vibewake.app.data.json
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/** Receives UnifiedPush messages (through the ntfy app) and shows them as notifications. */
class VibeWakePushService : PushService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val app get() = application as VibeWakeApp

    // If posting fails, Relay keeps the endpoint and retries when it next connects.
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        scope.launch { runCatching { app.relay.setPushEndpoint(endpoint.url) } }
    }

    // After unpairing this is a no-op: the relay deleted the device and its endpoint.
    override fun onUnregistered(instance: String) {
        scope.launch { runCatching { app.relay.setPushEndpoint(null) } }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {}

    override fun onMessage(message: PushMessage, instance: String) {
        val payload = runCatching { json.decodeFromString<PushPayload>(message.content.decodeToString()) }.getOrNull() ?: return
        show(payload)
    }

    private fun show(p: PushPayload) {
        val uri = if (p.sessionId.isNotEmpty()) "vibewake://machine/${p.machineId}/session/${p.sessionId}" else "vibewake://machine/${p.machineId}"
        val open = PendingIntent.getActivity(
            this, p.sessionId.hashCode(),
            Intent(Intent.ACTION_VIEW, Uri.parse(uri), this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val headline = when (p.kind) {
            "finished" -> "Finished: ${p.title}"
            "failed" -> "Failed: ${p.title}"
            "limited" -> "Usage limit: ${p.title}"
            "waiting" -> "Needs you: ${p.title}"
            else -> p.title
        }
        val n = NotificationCompat.Builder(this, VibeWakeApp.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(headline)
            .setContentText(p.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(p.text))
            .setSubText(p.machineName)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        // One notification per chat: a newer update replaces the older one.
        getSystemService(NotificationManager::class.java).notify(p.sessionId.ifEmpty { p.machineId }.hashCode(), n)
    }
}
