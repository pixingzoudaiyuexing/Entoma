package com.follow.clash

/** Main-thread lifecycle state; an Activity closing does not itself prove VPN closure. */
class VpnLifecycleGuard {
    enum class State { STOPPED, STARTING, RUNNING, STOPPING, STOP_FAILED }

    var state = State.STOPPED
        private set
    var exitRequested = false
        private set
    private var generation = 0L

    fun beginStart(): Long? {
        if (exitRequested || state != State.STOPPED) return null
        state = State.STARTING
        return ++generation
    }

    fun acceptsStart(token: Long) =
        !exitRequested && state == State.STARTING && token == generation

    fun canDeliverStarted(token: Long) =
        !exitRequested && state == State.RUNNING && token == generation

    fun started(token: Long): Boolean {
        if (!acceptsStart(token)) return false
        state = State.RUNNING
        return true
    }

    fun beginExit() {
        exitRequested = true
        ++generation
    }

    fun cancelExit(): Boolean {
        if (state == State.STOPPING) return false
        exitRequested = false
        return true
    }

    fun beginStop() {
        ++generation
        state = State.STOPPING
    }

    fun stopped() { state = State.STOPPED }
    fun stopFailed() { state = State.STOP_FAILED }
    fun canDestroy() = state == State.STOPPED
}
