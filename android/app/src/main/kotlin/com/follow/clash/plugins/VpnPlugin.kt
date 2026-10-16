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
import android.system.Os
import com.follow.clash.BuildConfig
import com.follow.clash.RunState
import com.follow.clash.VpnLifecycleGuard
import com.follow.clash.VpnStopTransaction
import com.follow.clash.VpnServiceRegistry
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
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger

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
    private val lifecycle = VpnLifecycleGuard()
    private var startGeneration = 0L
    private var stopTransaction: VpnStopTransaction? = null
    private var stopFailure: String? = null
    private var startPending = false
    private val uidPageNameMap = mutableMapOf<Int, String>()
    private var tunSequence = 0
    private var startedFd: Int? = null
    private data class OwnedTunFd(val number: Int, val device: Long?, val inode: Long?)
    private var ownedTunFd: OwnedTunFd? = null
    private val services = VpnServiceRegistry<BaseServiceInterface>(
        stop = { it.stop() }, awaitDestroyed = { it.destroyed.await() },
    )
    private var nativeStarts = 0
    private var nativeStops = 0
    private val protectedSockets = AtomicInteger(0)
    private val protectionFailures = AtomicInteger(0)

    fun acceptanceSnapshot(): Map<String, Any?> {
        if (!BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) return emptyMap()
        val fd = startedFd
        val openTunFd = if (fd == null) false else try {
            Os.readlink("/proc/self/fd/$fd").contains("tun")
        } catch (_: Exception) { false }
        val networks = connectivity?.allNetworks?.filter {
            connectivity?.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        } ?: emptyList()
        val httpProxy = networks.mapNotNull { connectivity?.getLinkProperties(it)?.httpProxy }.firstOrNull()
        return mapOf("runState" to GlobalState.runState.value?.name,
            "tunSequence" to tunSequence, "tunFd" to fd,
            "tunFdStillOpen" to openTunFd, "nativeStarts" to nativeStarts,
            "nativeStops" to nativeStops, "protectedSockets" to protectedSockets.get(),
            "protectionFailures" to protectionFailures.get(), "vpnNetworks" to networks.size,
            "vpnHttpProxyPresent" to (httpProxy != null),
            "vpnHttpProxyValid" to (httpProxy?.host == "127.0.0.1" &&
                httpProxy?.port == options?.port && httpProxy?.pacFileUrl?.toString().isNullOrEmpty()),
            "serviceIdentity" to flClashService?.let { System.identityHashCode(it) },
            "nativeLifecycle" to lifecycle.state.name, "exitRequested" to lifecycle.exitRequested,
            "stopInProgress" to (stopTransaction?.isActive == true), "stopFailure" to stopFailure)
    }

    private val connectivity by lazy {
        FlClashApplication.getAppContext().getSystemService<ConnectivityManager>()
    }

    private var pendingConnection: ServiceConnection? = null


    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        check(lifecycle.canDestroy()) { "Cannot attach an engine with unconfirmed VPN cleanup" }
        lifecycle.cancelExit()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        stopTransaction = VpnStopTransaction(scope, lifecycle)
        registerNetworkCallback()
        flutterMethodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "vpn")
        flutterMethodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        unRegisterNetworkCallback()
        flutterMethodChannel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val data = call.argument<String>("data")
                handleStart(Gson().fromJson(data, VpnOptions::class.java)) { started -> result.success(started) }
            }

            "stop" -> {
                handleStop { failure ->
                    if (failure == null) result.success(true)
                    else result.error("vpn_stop_failed", "VPN cleanup did not complete; retry stop", null)
                }
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    fun beginExit() {
        lifecycle.beginExit()
        cancelPendingStart()
    }

    fun cancelExit(): Boolean {
        if (stopTransaction?.isActive == true) return false
        return lifecycle.cancelExit()
    }

    fun isNativeRunning() = lifecycle.state == VpnLifecycleGuard.State.RUNNING

    fun canSyncStatus() = lifecycle.state == VpnLifecycleGuard.State.RUNNING || lifecycle.canDestroy()

    fun onServiceCreated(service: BaseServiceInterface) {
        val stopping = lifecycle.exitRequested || lifecycle.state == VpnLifecycleGuard.State.STOPPING ||
            lifecycle.state == VpnLifecycleGuard.State.STOP_FAILED
        services.add(service, stopping)
        if (!stopping) flClashService = service
    }

    fun onServiceDestroyed(service: BaseServiceInterface) {
        services.remove(service)
        if (flClashService === service &&
            (lifecycle.state == VpnLifecycleGuard.State.RUNNING || lifecycle.state == VpnLifecycleGuard.State.STARTING)) {
            handleStop()
        }
    }

    fun canDestroyEngine(): Boolean = lifecycle.canDestroy() &&
        stopTransaction?.isActive != true && flClashService == null && pendingConnection == null && services.isEmpty

    fun handleStart(options: VpnOptions, completion: ((Boolean) -> Unit)? = null): Boolean {
        if (lifecycle.exitRequested || stopTransaction?.isActive == true) {
            completion?.invoke(false)
            return false
        }
        if (lifecycle.state == VpnLifecycleGuard.State.RUNNING && options == this.options) {
            completion?.invoke(true)
            return true
        }
        scope.launch {
            try {
                // A failed previous stop must be reconciled before a fresh start.
                stopVpn()
                val generation = lifecycle.beginStart()
                if (generation == null) { completion?.invoke(false); return@launch }
                startGeneration = generation
                startPending = true
                startCompletion = completion
                this@VpnPlugin.options = options
                startDeadline = scope.launch {
                    delay(30000)
                    if (lifecycle.acceptsStart(generation) && startPending) handleStop()
                }
                onUpdateNetwork()
                if (options.enable) handleStartVpn() else handleStartService()
            } catch (_: Exception) {
                completion?.invoke(false)
            }
        }
        return true
    }

    private fun finishStart(started: Boolean) {
        startPending = false
        startDeadline?.cancel()
        startDeadline = null
        val callback = startCompletion
        startCompletion = null
        val generation = startGeneration
        if (callback != null) CoroutineScope(Dispatchers.Main).launch {
            // Authorization/Binder success may be queued just before shutdown invalidates its token.
            callback(started && generation == startGeneration && lifecycle.canDeliverStarted(generation))
        }
    }

    private fun cancelPendingStart() {
        ++startGeneration
        finishStart(false)
        GlobalState.getCurrentAppPlugin()?.cancelVpnPermissionRequest()
    }

    private fun unbindService() {
        val previous = pendingConnection
        if (previous != null) {
            FlClashApplication.getAppContext().unbindService(previous)
            pendingConnection = null
        }
        isBind = false
    }

    private fun handleStartVpn() {
        val generation = startGeneration
        GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
            if (generation == startGeneration && lifecycle.acceptsStart(generation) && startPending) handleStartService()
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
        if (lifecycle.exitRequested || lifecycle.state != VpnLifecycleGuard.State.RUNNING) return
        val generation = startGeneration
        val service = flClashService ?: return
        val data = flutterMethodChannel.awaitResult<String>("getStartForegroundParams")
        if (lifecycle.exitRequested || generation != startGeneration || lifecycle.state != VpnLifecycleGuard.State.RUNNING ||
            service !== flClashService) return
        val params = if (data != null) Gson().fromJson(data, StartForegroundParams::class.java)
                     else StartForegroundParams(title = "", content = "")
        if (lastStartForegroundParams != params) {
            service.startForeground(params.title, params.content)
            lastStartForegroundParams = params
        }
    }

    private fun startForegroundJob() {
        stopForegroundJob()
        timerJob = scope.launch {
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
        val generation = startGeneration
        if (!startPending || !lifecycle.acceptsStart(generation)) return
        if (flClashService == null) {
            bindService()
            return
        }
        try {
            val fd = flClashService!!.start(options!!)
            if (options?.enable == true && fd <= 0) throw IllegalStateException("VPN interface unavailable")
            if (options?.enable == true) {
                // Observe the already detached FD; never duplicate/adopt/close it from Java.
                val identity = try { Os.stat("/proc/self/fd/$fd") } catch (_: android.system.ErrnoException) { null }
                ownedTunFd = OwnedTunFd(fd, identity?.st_dev, identity?.st_ino)
            }
            if (BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) { startedFd = fd; tunSequence++ }
            val started = Core.startTun(fd = fd, protect = this::protect, resolverProcess = this::resolverProcess)
            if (!started) throw IllegalStateException("TUN start failed")
            if (BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) nativeStarts++
            check(lifecycle.started(generation)) { "VPN start superseded by shutdown" }
            GlobalState.runState.value = RunState.START
            startForegroundJob()
            finishStart(true)
        } catch (_: Exception) {
            // One cleanup path, including partial startup; never report STOP before it finishes.
            handleStop()
        }
    }

    private fun protect(fd: Int): Boolean {
        val protected = (flClashService as? FlClashVpnService)?.protect(fd) == true
        if (BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) {
            if (protected) protectedSockets.incrementAndGet() else protectionFailures.incrementAndGet()
        }
        return protected
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

    /** All callers join this transaction; a failed stop retains the engine and service identity. */
    private suspend fun stopVpn() {
        try {
            checkNotNull(stopTransaction).stop {
                cancelPendingStart()
                stopForegroundJob()
                if (GlobalState.runState.value != RunState.STOP) GlobalState.runState.value = RunState.PENDING
                // Go owns the detached TUN FD. A synchronous native return precedes service teardown.
                withContext(Dispatchers.IO) { Core.stopTun() }
                verifyTunClosed()
                android.util.Log.i("EntomaVpn", "Native stop returned; owned TUN absent fd=${ownedTunFd?.number ?: 0}")
                if (BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) nativeStops++
                services.stopAndAwaitDestroyed(this::unbindService)
                android.util.Log.i("EntomaVpn", "VPN services destroyed and binding released")
                flClashService = null
                ownedTunFd = null
                lastStartForegroundParams = null
                stopFailure = null
                GlobalState.runState.value = RunState.STOP
            }
        } catch (failure: Exception) {
            stopFailure = failure.javaClass.simpleName
            android.util.Log.w("EntomaVpn", "VPN stop incomplete: ${failure.javaClass.simpleName}")
            // PENDING intentionally preserves an unresolved native state for retry/diagnostics.
            GlobalState.runState.value = RunState.PENDING
            throw failure
        }
    }

    private fun verifyTunClosed() {
        val owned = ownedTunFd ?: return
        val path = "/proc/self/fd/${owned.number}"
        val link = try { Os.readlink(path) } catch (failure: android.system.ErrnoException) {
            if (failure.errno == android.system.OsConstants.ENOENT) return
            throw failure
        }
        // A reused numeric FD must never be closed here. A remaining TUN identity is unresolved.
        if (link.contains("tun")) {
            val identity = try { Os.stat(path) } catch (failure: android.system.ErrnoException) {
                if (failure.errno == android.system.OsConstants.ENOENT) return
                throw failure
            }
            check(owned.device != null && owned.inode != null &&
                (identity.st_dev != owned.device || identity.st_ino != owned.inode)) {
                "TUN descriptor is still open after native stop"
            }
        }
    }

    fun handleStop(completion: ((Throwable?) -> Unit)? = null) {
        scope.launch {
            try { stopVpn(); completion?.invoke(null) }
            catch (failure: Exception) { completion?.invoke(failure) }
        }
    }

    private fun bindService() {
        check(pendingConnection == null)
        val generation = startGeneration
        val expectsVpn = options?.enable == true
        val connection = object : ServiceConnection {
            override fun onServiceConnected(className: ComponentName, binder: IBinder) {
                if (generation != startGeneration || !lifecycle.acceptsStart(generation) || !startPending || pendingConnection !== this) {
                    // The stop transaction owns the current binding, including late callbacks.
                    if (pendingConnection !== this) {
                        try { FlClashApplication.getAppContext().unbindService(this) } catch (_: IllegalArgumentException) {}
                    }
                    return
                }
                val bound = when (binder) {
                    is FlClashVpnService.LocalBinder -> if (expectsVpn) binder.getService() else null
                    is FlClashService.LocalBinder -> if (!expectsVpn) binder.getService() else null
                    else -> null
                }
                if (bound == null) { handleStop(); return }
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
            pendingConnection = null
            handleStop()
        }
    }
}
