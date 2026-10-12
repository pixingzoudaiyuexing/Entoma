package com.follow.clash.plugins

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import androidx.core.content.getSystemService
import com.follow.clash.FlClashApplication
import com.follow.clash.GlobalState
import com.follow.clash.RunState
import com.follow.clash.core.Core
import com.follow.clash.extensions.awaitResult
import com.follow.clash.extensions.resolveDns
import com.follow.clash.models.StartForegroundParams
import com.follow.clash.models.VpnOptions
import com.follow.clash.services.BaseServiceInterface
import com.follow.clash.services.FlClashService
import com.follow.clash.services.FlClashVpnService
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import kotlin.concurrent.withLock

data object VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var flutterMethodChannel: MethodChannel
    private var flClashService: BaseServiceInterface? = null
    private var options: VpnOptions? = null
    private var isBind: Boolean = false
    private lateinit var scope: CoroutineScope
    private var lastStartForegroundParams: StartForegroundParams? = null
    private var timerJob: Job? = null
    private var startDeadline: Job? = null
    private var startCompletion: ((Boolean) -> Unit)? = null
    private var startGeneration = 0
    private var startPending = false
    private val uidPageNameMap = mutableMapOf<Int, String>()

    private val connectivity by lazy {
        FlClashApplication.getAppContext().getSystemService<ConnectivityManager>()
    }

    private var pendingConnection: ServiceConnection? = null


    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(Dispatchers.Default)
        scope.launch {
            registerNetworkCallback()
        }
        flutterMethodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "vpn")
        flutterMethodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        unRegisterNetworkCallback()
        flutterMethodChannel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val data = call.argument<String>("data")
                handleStart(Gson().fromJson(data, VpnOptions::class.java)) { started -> result.success(started) }
            }

            "stop" -> {
                handleStop()
                result.success(true)
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    fun handleStart(options: VpnOptions, completion: ((Boolean) -> Unit)? = null): Boolean {
        if (GlobalState.runState.value == RunState.START && options == this.options) {
            completion?.invoke(true)
            return true
        }
        handleStop()
        val generation = ++startGeneration
        startPending = true
        startCompletion = completion
        startDeadline = CoroutineScope(Dispatchers.Main).launch {
            delay(30000)
            if (generation != startGeneration || !startPending) return@launch
            handleStop()
            finishStart(false)
        }
        onUpdateNetwork();
        if (options.enable != this.options?.enable) {
            this.flClashService = null
        }
        this.options = options
        when (options.enable) {
            true -> handleStartVpn()
            false -> handleStartService()
        }
        return true
    }

    private fun finishStart(started: Boolean) {
        startPending = false
        startDeadline?.cancel()
        startDeadline = null
        val callback = startCompletion
        startCompletion = null
        if (callback != null) CoroutineScope(Dispatchers.Main).launch { callback(started) }
    }

    private fun cancelPendingStart() {
        ++startGeneration
        finishStart(false)
        unbindService()
    }

    private fun unbindService() {
        val previous = pendingConnection
        pendingConnection = null
        if (previous != null) {
            try { FlClashApplication.getAppContext().unbindService(previous) } catch (_: Exception) {}
        }
        isBind = false
        flClashService = null
    }

    private fun handleStartVpn() {
        val generation = startGeneration
        GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
            if (generation == startGeneration && startPending) handleStartService()
        }
    }

    fun requestGc() {
        flutterMethodChannel.invokeMethod("gc", null)
    }

    val networks = mutableSetOf<Network>()

    fun onUpdateNetwork() {
        val dns = networks.flatMap { network ->
            connectivity?.resolveDns(network) ?: emptyList()
        }.toSet().joinToString(",")
        scope.launch {
            withContext(Dispatchers.Main) {
                flutterMethodChannel.invokeMethod("dnsChanged", dns)
            }
        }
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networks.add(network)
            onUpdateNetwork()
        }

        override fun onLost(network: Network) {
            networks.remove(network)
            onUpdateNetwork()
        }
    }

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private fun registerNetworkCallback() {
        networks.clear()
        connectivity?.registerNetworkCallback(request, callback)
    }

    private fun unRegisterNetworkCallback() {
        connectivity?.unregisterNetworkCallback(callback)
        networks.clear()
        onUpdateNetwork()
    }

    private suspend fun startForeground() {
        GlobalState.runLock.lock()
        try {
            if (GlobalState.runState.value != RunState.START) return
            val data = flutterMethodChannel.awaitResult<String>("getStartForegroundParams")
            val startForegroundParams = if (data != null) Gson().fromJson(
                data, StartForegroundParams::class.java
            ) else StartForegroundParams(
                title = "", content = ""
            )
            if (lastStartForegroundParams != startForegroundParams) {
                lastStartForegroundParams = startForegroundParams
                flClashService?.startForeground(
                    startForegroundParams.title,
                    startForegroundParams.content,
                )
            }
        } finally {
            GlobalState.runLock.unlock()
        }
    }

    private fun startForegroundJob() {
        stopForegroundJob()
        timerJob = CoroutineScope(Dispatchers.Main).launch {
            while (isActive) {
                startForeground()
                delay(1000)
            }
        }
    }

    private fun stopForegroundJob() {
        timerJob?.cancel()
        timerJob = null
    }


    suspend fun getStatus(): Boolean? {
        return withContext(Dispatchers.Default) {
            flutterMethodChannel.awaitResult<Boolean>("status", null)
        }
    }

    private fun handleStartService() {
        if (!startPending) return
        if (flClashService == null) {
            bindService()
            return
        }
        GlobalState.runLock.withLock {
            if (GlobalState.runState.value == RunState.START) { finishStart(true); return }
            try {
            val fd = flClashService?.start(options!!)
            if (options?.enable == true && (fd == null || fd <= 0)) throw IllegalStateException("VPN interface unavailable")
            val started = Core.startTun(
                fd = fd ?: 0,
                protect = this::protect,
                resolverProcess = this::resolverProcess,
            )
            if (!started) throw IllegalStateException("TUN start failed")
            GlobalState.runState.value = RunState.START
            startForegroundJob()
            finishStart(true)
            } catch (_: Exception) {
                flClashService?.stop()
                Core.stopTun()
                GlobalState.runState.value = RunState.STOP
                finishStart(false)
            }
        }
    }

    private fun protect(fd: Int): Boolean {
        return (flClashService as? FlClashVpnService)?.protect(fd) == true
    }

    private fun resolverProcess(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
        uid: Int,
    ): String {
        val nextUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
        } else {
            uid
        }
        if (nextUid == -1) {
            return ""
        }
        if (!uidPageNameMap.containsKey(nextUid)) {
            uidPageNameMap[nextUid] =
                FlClashApplication.getAppContext().packageManager?.getPackagesForUid(nextUid)
                    ?.first() ?: ""
        }
        return uidPageNameMap[nextUid] ?: ""
    }

    fun handleStop() {
        val activeService = flClashService
        cancelPendingStart()
        if (GlobalState.runState.value == RunState.STOP) { activeService?.stop(); return }
        GlobalState.runLock.withLock {
            if (GlobalState.runState.value == RunState.STOP) return
            GlobalState.runState.value = RunState.STOP
            activeService?.stop()
            stopForegroundJob()
            Core.stopTun()
            GlobalState.handleTryDestroy()
        }
    }

    private fun bindService() {
        unbindService()
        val generation = startGeneration
        val expectsVpn = options?.enable == true
        val connection = object : ServiceConnection {
            override fun onServiceConnected(className: ComponentName, binder: IBinder) {
                if (generation != startGeneration || !startPending || pendingConnection !== this) {
                    try { FlClashApplication.getAppContext().unbindService(this) } catch (_: Exception) {}
                    return
                }
                val bound = when (binder) {
                    is FlClashVpnService.LocalBinder -> if (expectsVpn) binder.getService() else null
                    is FlClashService.LocalBinder -> if (!expectsVpn) binder.getService() else null
                    else -> null
                }
                if (bound == null) { finishStart(false); unbindService(); return }
                isBind = true
                flClashService = bound
                handleStartService()
            }
            override fun onServiceDisconnected(className: ComponentName) {
                if (generation == startGeneration && pendingConnection === this) {
                    handleStop()
                }
            }
        }
        pendingConnection = connection
        val intent = if (expectsVpn) Intent(FlClashApplication.getAppContext(), FlClashVpnService::class.java)
                     else Intent(FlClashApplication.getAppContext(), FlClashService::class.java)
        if (!FlClashApplication.getAppContext().bindService(intent, connection, Context.BIND_AUTO_CREATE)) {
            finishStart(false)
            unbindService()
        }
    }
}
