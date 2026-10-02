package com.vibewake.app.data

import android.content.Context

/**
 * The relay URL and this phone's device token. Kept in app-private storage
 * (not backed up: allowBackup is off), so only this app can read it.
 */
class Credentials(context: Context) {
    private val prefs = context.getSharedPreferences("relay", Context.MODE_PRIVATE)

    val server: String? get() = prefs.getString("server", null)
    val token: String? get() = prefs.getString("token", null)
    val paired get() = server != null && token != null

    /** Last UnifiedPush endpoint sent to the relay, to avoid re-sending it. */
    var pushEndpoint: String?
        get() = prefs.getString("pushEndpoint", null)
        set(v) = prefs.edit().putString("pushEndpoint", v).apply()

    fun save(server: String, token: String) {
        prefs.edit().putString("server", server).putString("token", token).remove("pushEndpoint").apply()
    }

    fun clear() = prefs.edit().clear().apply()
}
