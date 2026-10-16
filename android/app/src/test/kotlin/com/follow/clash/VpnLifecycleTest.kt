package com.follow.clash

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.coroutines.TimeoutCancellationException
import org.junit.Assert.*
import org.junit.Test

class VpnLifecycleTest {
    @Test fun queuedSuccessCannotBeDeliveredAfterExitStopOrANewerConnection() {
        val lifecycle = VpnLifecycleGuard()
        val old = lifecycle.beginStart()!!
        assertTrue(lifecycle.started(old))
        assertTrue(lifecycle.canDeliverStarted(old))
        lifecycle.beginExit()
        assertFalse(lifecycle.canDeliverStarted(old))
        lifecycle.beginStop()
        lifecycle.stopped()
        assertTrue(lifecycle.cancelExit())
        val replacement = lifecycle.beginStart()!!
        assertTrue(lifecycle.started(replacement))
        assertTrue(lifecycle.canDeliverStarted(replacement))
        assertFalse(lifecycle.canDeliverStarted(old))
    }

    @Test fun latePermissionAndBinderTokensCannotStartAfterExit() {
        val lifecycle = VpnLifecycleGuard()
        val token = lifecycle.beginStart()!!
        assertTrue(lifecycle.acceptsStart(token))
        lifecycle.beginExit()
        assertFalse(lifecycle.acceptsStart(token))
        assertFalse(lifecycle.started(token))
        assertNull(lifecycle.beginStart())
        lifecycle.beginStop()
        lifecycle.stopped()
        assertNull(lifecycle.beginStart())
        assertTrue(lifecycle.cancelExit())
        assertNotEquals(token, lifecycle.beginStart())
        assertFalse(lifecycle.acceptsStart(token))
    }

    @Test fun backgroundActivityDoesNotChangeRunningVpnState() {
        val lifecycle = VpnLifecycleGuard()
        assertTrue(lifecycle.started(lifecycle.beginStart()!!))
        // Minimizing does not request exit or stop; returning to the same running VPN is valid.
        assertFalse(lifecycle.exitRequested)
        assertEquals(VpnLifecycleGuard.State.RUNNING, lifecycle.state)
        assertFalse(lifecycle.canDestroy())
        assertNull(lifecycle.beginStart())
    }

    @Test fun slowRealAcknowledgementAndConcurrentStopsAreSingleFlight() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val lifecycle = VpnLifecycleGuard()
            lifecycle.started(lifecycle.beginStart()!!)
            lifecycle.beginExit()
            val stop = VpnStopTransaction(scope, lifecycle)
            val nativeClosed = CompletableDeferred<Unit>()
            val serviceDestroyed = CompletableDeferred<Unit>()
            val order = mutableListOf<String>()
            val first = async {
                stop.stop {
                    order += "stopTun-enter"
                    nativeClosed.await()
                    order += "stopTun-return"
                    order += "stopForeground/unbind"
                    serviceDestroyed.await()
                    order += "service-onDestroy"
                }
                order += "engine-destroy-allowed"
            }
            yield()
            val second = async { stop.stop { error("duplicate cleanup must not run") } }
            delay(350)
            assertFalse(first.isCompleted)
            assertFalse(second.isCompleted)
            assertFalse(lifecycle.canDestroy())
            assertFalse(lifecycle.cancelExit())
            assertNull(lifecycle.beginStart())
            nativeClosed.complete(Unit)
            yield()
            assertFalse(first.isCompleted)
            assertEquals(listOf("stopTun-enter", "stopTun-return", "stopForeground/unbind"), order)
            serviceDestroyed.complete(Unit)
            first.await(); second.await()
            assertEquals(listOf("stopTun-enter", "stopTun-return", "stopForeground/unbind", "service-onDestroy", "engine-destroy-allowed"), order)
            assertTrue(lifecycle.canDestroy())
        } finally { scope.cancel() }
    }

    @Test fun failedStopBlocksDestructionAndCanBeRetried() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val lifecycle = VpnLifecycleGuard()
            lifecycle.started(lifecycle.beginStart()!!)
            lifecycle.beginExit()
            val stop = VpnStopTransaction(scope, lifecycle)
            try {
                stop.stop { throw IllegalStateException("native stop failed") }
                fail("must propagate stop failure")
            } catch (_: IllegalStateException) { }
            assertEquals(VpnLifecycleGuard.State.STOP_FAILED, lifecycle.state)
            assertFalse(lifecycle.canDestroy())
            assertFalse(stop.isActive)
            assertTrue(lifecycle.cancelExit())
            // Cancelling the UI exit cannot silently release an unresolved VPN lock.
            assertNull(lifecycle.beginStart())
            stop.stop { }
            assertTrue(lifecycle.canDestroy())
            assertNotNull(lifecycle.beginStart())
        } finally { scope.cancel() }
    }

    @Test fun repeatedStopAndRepeatedExitDoNotRevalidateOldCallbacks() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val lifecycle = VpnLifecycleGuard()
            val old = lifecycle.beginStart()!!
            lifecycle.beginExit(); lifecycle.beginExit()
            val stop = VpnStopTransaction(scope, lifecycle)
            stop.stop { }; stop.stop { }
            assertTrue(lifecycle.canDestroy())
            assertFalse(lifecycle.acceptsStart(old))
            assertTrue(lifecycle.cancelExit())
            val new = lifecycle.beginStart()!!
            assertFalse(lifecycle.acceptsStart(old))
            assertTrue(lifecycle.acceptsStart(new))
        } finally { scope.cancel() }
    }

    @Test fun callerTimeoutRetainsCleanupFlightAndRetryJoinsIt() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val lifecycle = VpnLifecycleGuard()
            lifecycle.started(lifecycle.beginStart()!!)
            lifecycle.beginExit()
            val stop = VpnStopTransaction(scope, lifecycle)
            val nativeReturn = CompletableDeferred<Unit>()
            var invocations = 0
            try {
                stop.stop(timeoutMillis = 20) { ++invocations; nativeReturn.await() }
                fail("unreturned native stop must time out")
            } catch (_: TimeoutCancellationException) { }
            assertEquals(1, invocations)
            assertTrue(stop.isActive)
            assertFalse(lifecycle.canDestroy())
            assertEquals(VpnLifecycleGuard.State.STOP_FAILED, lifecycle.state)
            val retry = async { stop.stop { error("retry must join still-running native stop") } }
            yield()
            assertFalse(retry.isCompleted)
            nativeReturn.complete(Unit)
            retry.await()
            assertEquals(1, invocations)
            assertFalse(stop.isActive)
            assertTrue(lifecycle.canDestroy())
        } finally { scope.cancel() }
    }

    @Test fun lateServiceCreationDuringStopIsStoppedAndItsDestructionAwaited() = runBlocking {
        class Service {
            val destroyed = CompletableDeferred<Unit>()
            var stopCalls = 0
        }
        val registry = VpnServiceRegistry<Service>(
            stop = { ++it.stopCalls }, awaitDestroyed = { it.destroyed.await() },
        )
        val initial = Service()
        registry.add(initial, stopping = false)
        val cleanup = async { registry.stopAndAwaitDestroyed { } }
        yield()
        assertEquals(1, initial.stopCalls)
        val late = Service()
        registry.add(late, stopping = true)
        assertEquals(1, late.stopCalls)
        registry.remove(initial); initial.destroyed.complete(Unit)
        yield()
        assertFalse(cleanup.isCompleted)
        assertFalse(registry.isEmpty)
        registry.remove(late); late.destroyed.complete(Unit)
        cleanup.await()
        assertTrue(registry.isEmpty)
    }
}
