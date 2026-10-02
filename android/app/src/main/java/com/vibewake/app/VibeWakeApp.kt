package com.vibewake.app

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.vibewake.app.data.Credentials
import com.vibewake.app.data.Relay

class VibeWakeApp : Application() {
    lateinit var credentials: Credentials
        private set
    lateinit var relay: Relay
        private set

    override fun onCreate() {
        super.onCreate()
        credentials = Credentials(this)
        relay = Relay(credentials)

        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_EVENTS, getString(R.string.channel_events), NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = getString(R.string.channel_events_desc) },
        )

        // Live connection only while the app is visible; push notifications cover the rest.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = relay.start()
            override fun onStop(owner: LifecycleOwner) = relay.stop()
        })
    }

    companion object {
        const val CHANNEL_EVENTS = "events"
    }
}
