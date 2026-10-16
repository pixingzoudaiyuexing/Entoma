package com.follow.clash.services

import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.follow.clash.GlobalState
import com.follow.clash.models.VpnOptions
import kotlinx.coroutines.CompletableDeferred


class FlClashService : Service(), BaseServiceInterface {
    override val destroyed = CompletableDeferred<Unit>()

    override fun onCreate() {
        super.onCreate()
        GlobalState.getCurrentVPNPlugin()?.onServiceCreated(this)
        if (GlobalState.isExitRequested) stop()
    }

    override fun start(options: VpnOptions) = 0

    override fun stop() {
        stopSelf()
        stopFlClashForeground()
    }
    
    private var cachedBuilder: NotificationCompat.Builder? = null

    private suspend fun notificationBuilder(): NotificationCompat.Builder {
        if (cachedBuilder == null) {
            cachedBuilder = createFlClashNotificationBuilder().await()
        }
        return cachedBuilder!!
    }

    @SuppressLint("ForegroundServiceType")
    override suspend fun startForeground(title: String, content: String) {
        val builder = notificationBuilder()
        // Notification text can await Dart; cleanup may finish while that reply is pending.
        if (destroyed.isCompleted || GlobalState.isExitRequested ||
            GlobalState.getCurrentVPNPlugin()?.isNativeRunning() != true) return
        startForeground(
            builder
                .setContentTitle(title)
                .setContentText(content).build()
        )
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        GlobalState.getCurrentVPNPlugin()?.requestGc()
    }


    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): FlClashService = this@FlClashService
    }

    override fun onBind(intent: Intent): IBinder {
        return binder
    }

    override fun onUnbind(intent: Intent?): Boolean {
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        try {
            stop()
            super.onDestroy()
            destroyed.complete(Unit)
            GlobalState.getCurrentVPNPlugin()?.onServiceDestroyed(this)
        } catch (error: Exception) {
            destroyed.completeExceptionally(error)
            throw error
        }
    }
}
