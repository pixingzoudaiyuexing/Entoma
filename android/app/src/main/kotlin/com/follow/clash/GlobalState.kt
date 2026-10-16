package com.follow.clash

import androidx.lifecycle.MutableLiveData
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.plugins.VpnPlugin
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

enum class RunState {
    START,
    PENDING,
    STOP
}


object GlobalState {
    val runLock = ReentrantLock()

    const val NOTIFICATION_CHANNEL = "FlClash"

    const val NOTIFICATION_ID = 1

    val runState: MutableLiveData<RunState> = MutableLiveData<RunState>(RunState.STOP)
    var flutterEngine: FlutterEngine? = null
    private var serviceEngine: FlutterEngine? = null
    var isExitRequested = false
        private set

    fun beginExit() {
        isExitRequested = true
        getCurrentAppPlugin()?.cancelVpnPermissionRequest()
        getCurrentVPNPlugin()?.beginExit()
    }

    fun cancelExit(): Boolean {
        if (getCurrentVPNPlugin()?.cancelExit() == false) return false
        isExitRequested = false
        return true
    }

    fun attachMainEngine(engine: FlutterEngine) {
        if (serviceEngine == null && VpnPlugin.canDestroyEngine()) isExitRequested = false
        flutterEngine = engine
    }

    fun getCurrentAppPlugin(): AppPlugin? {
        val currentEngine = if (flutterEngine != null) flutterEngine else serviceEngine
        return currentEngine?.plugins?.get(AppPlugin::class.java) as AppPlugin?
    }

    fun syncStatus() {
        if (isExitRequested) return
        val plugin = getCurrentVPNPlugin()
        CoroutineScope(Dispatchers.Default).launch {
            plugin?.getStatus()
            withContext(Dispatchers.Main){
                if (!isExitRequested && plugin === getCurrentVPNPlugin() &&
                    plugin?.canSyncStatus() != false) {
                    // A Dart/UI status response cannot prove that native VPN resources disappeared.
                    runState.value = if (plugin?.isNativeRunning() == true) RunState.START else RunState.STOP
                }
            }
        }
    }

    suspend fun getText(text: String): String {
        return getCurrentAppPlugin()?.getText(text) ?: ""
    }

    fun getCurrentTilePlugin(): TilePlugin? {
        val currentEngine = if (flutterEngine != null) flutterEngine else serviceEngine
        return currentEngine?.plugins?.get(TilePlugin::class.java) as TilePlugin?
    }

    fun getCurrentVPNPlugin(): VpnPlugin? {
        return serviceEngine?.plugins?.get(VpnPlugin::class.java) as VpnPlugin?
    }

    fun handleToggle() {
        val starting = handleStart()
        if (!starting) {
            handleStop()
        }
    }

    fun handleStart(): Boolean {
        if (isExitRequested) return false
        if (runState.value == RunState.STOP) {
            runState.value = RunState.PENDING
            runLock.lock()
            val tilePlugin = getCurrentTilePlugin()
            if (tilePlugin != null) {
                tilePlugin.handleStart()
            } else {
                initServiceEngine()
            }
            return true
        }
        return false
    }

    fun handleStop() {
        if (runState.value == RunState.START) {
            runState.value = RunState.PENDING
            runLock.lock()
            getCurrentTilePlugin()?.handleStop()
        }
    }

    fun handleTryDestroy() {
        if (flutterEngine == null) {
            destroyServiceEngine()
        }
    }

    fun destroyServiceEngine(): Boolean = runLock.withLock {
            if (serviceEngine != null && !VpnPlugin.canDestroyEngine()) return false
            serviceEngine?.destroy()
            serviceEngine = null
            true
    }

    fun initServiceEngine(): Boolean {
        if (isExitRequested) return false
        if (serviceEngine != null) return true
        runLock.withLock {
            serviceEngine = FlutterEngine(FlClashApplication.getAppContext())
            serviceEngine?.plugins?.add(VpnPlugin)
            serviceEngine?.plugins?.add(AppPlugin())
            serviceEngine?.plugins?.add(TilePlugin())
            val vpnService = DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "_service"
            )
            serviceEngine?.dartExecutor?.executeDartEntrypoint(
                vpnService,
                if (flutterEngine == null) listOf("quick") else null
            )
        }
        return true
    }
}


