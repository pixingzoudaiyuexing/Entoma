package com.follow.clash

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/** Called on Main: all stop callers await the same real cleanup, including slow native calls. */
class VpnStopTransaction(
    private val scope: CoroutineScope,
    private val lifecycle: VpnLifecycleGuard,
) {
    private var flight: Deferred<Unit>? = null
    val isActive: Boolean get() = flight?.isActive == true

    suspend fun stop(timeoutMillis: Long = 15000, cleanup: suspend () -> Unit) {
        val pending = flight
        if (pending != null) { awaitCleanup(pending, timeoutMillis); return }
        lifecycle.beginStop()
        val operation = scope.async(start = CoroutineStart.LAZY) {
            try {
                cleanup()
                lifecycle.stopped()
            } catch (failure: Exception) {
                lifecycle.stopFailed()
                throw failure
            } finally {
                flight = null
            }
        }
        flight = operation
        operation.start()
        awaitCleanup(operation, timeoutMillis)
    }

    private suspend fun awaitCleanup(operation: Deferred<Unit>, timeoutMillis: Long) {
        try {
            withTimeout(timeoutMillis) { operation.await() }
        } catch (failure: TimeoutCancellationException) {
            // Only the caller's wait expires. Native cleanup still owns the flight and its resources.
            if (operation.isActive) lifecycle.stopFailed()
            throw failure
        }
    }
}
