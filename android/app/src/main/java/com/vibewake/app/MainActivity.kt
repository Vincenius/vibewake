package com.vibewake.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import com.vibewake.app.ui.MachineScreen
import com.vibewake.app.ui.MachinesScreen
import com.vibewake.app.ui.PairScreen
import com.vibewake.app.ui.SessionScreen
import com.vibewake.app.ui.VibeWakeTheme
import com.vibewake.app.ui.parsePairLink
import org.unifiedpush.android.connector.UnifiedPush

class MainActivity : ComponentActivity() {
    private val app get() = application as VibeWakeApp
    /** A vibewake://pair link this activity was opened with, for the pairing screen. */
    private var pairLink by mutableStateOf<String?>(null)
    private var pushHint by mutableStateOf<String?>(null)
    private var nav: NavHostController? = null

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { setUpPush() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        takePairLink(intent)
        setContent {
            VibeWakeTheme {
                val state by app.relay.state.collectAsStateWithLifecycle()
                val snackbar = remember { SnackbarHostState() }
                LaunchedEffect(Unit) { app.relay.messages.collect { snackbar.showSnackbar(it) } }
                val navController = rememberNavController().also { nav = it }
                val start = if (app.credentials.paired && pairLink == null) "machines" else "pair"

                NavHost(navController, startDestination = start) {
                    composable("pair") {
                        PairScreen(app.relay, pairLink) {
                            pairLink = null
                            navController.navigate("machines") { popUpTo("pair") { inclusive = true } }
                            askForNotifications()
                        }
                    }
                    composable("machines") {
                        MachinesScreen(
                            state, snackbar, pushHint,
                            onOpen = { navController.navigate("machine/${it.id}") },
                            onSetUpPush = { askForNotifications(force = true) },
                            onUnpair = {
                                UnifiedPush.unregister(this@MainActivity)
                                app.relay.unpair()
                                navController.navigate("pair") { popUpTo(0) }
                            },
                        )
                    }
                    composable(
                        "machine/{machineId}",
                        arguments = listOf(navArgument("machineId") { type = NavType.StringType }),
                        deepLinks = listOf(navDeepLink { uriPattern = "vibewake://machine/{machineId}" }),
                    ) { entry ->
                        val machineId = entry.arguments!!.getString("machineId")!!
                        MachineScreen(app.relay, state, machineId, snackbar, onBack = { back(navController) }) {
                            navController.navigate("session/$machineId/${it.id}")
                        }
                    }
                    composable(
                        "session/{machineId}/{sessionId}",
                        arguments = listOf(
                            navArgument("machineId") { type = NavType.StringType },
                            navArgument("sessionId") { type = NavType.StringType },
                        ),
                        deepLinks = listOf(navDeepLink { uriPattern = "vibewake://machine/{machineId}/session/{sessionId}" }),
                    ) { entry ->
                        val a = entry.arguments!!
                        SessionScreen(app.relay, state, a.getString("machineId")!!, a.getString("sessionId")!!, snackbar,
                            onBack = { back(navController) })
                    }
                }
            }
        }
        if (app.credentials.paired) setUpPush()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (takePairLink(intent)) {
            nav?.navigate("pair")
        } else {
            nav?.handleDeepLink(intent)
        }
    }

    private fun takePairLink(intent: Intent?): Boolean {
        val data = intent?.dataString ?: return false
        if (parsePairLink(data) == null) return false
        pairLink = data
        return true
    }

    /** Opened from a notification, there may be nothing to go back to. */
    private fun back(nav: NavHostController) {
        if (!nav.popBackStack()) nav.navigate("machines") { popUpTo(0) }
    }

    private fun askForNotifications(force: Boolean = false) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            setUpPush(force)
        }
    }

    /** Register with the UnifiedPush distributor (the ntfy app); the endpoint arrives in VibeWakePushService. */
    private fun setUpPush(pick: Boolean = false) {
        val done: (Boolean) -> Unit = { ok ->
            if (ok) {
                UnifiedPush.register(this)
                pushHint = null
            } else {
                pushHint = "For notifications, install the ntfy app and point it at your ntfy server, then choose Notifications… in the menu."
            }
        }
        if (pick) UnifiedPush.tryPickDistributor(this, done) else UnifiedPush.tryUseCurrentOrDefaultDistributor(this, done)
    }
}
