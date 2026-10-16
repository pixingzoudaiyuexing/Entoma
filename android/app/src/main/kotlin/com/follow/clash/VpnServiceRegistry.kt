package com.follow.clash

import java.util.Collections
import java.util.IdentityHashMap
import kotlinx.coroutines.yield

/** Main-thread service identities, including creation before the Binder delivery. */
class VpnServiceRegistry<T : Any>(
    private val stop: (T) -> Unit,
    private val awaitDestroyed: suspend (T) -> Unit,
) {
    private val active = Collections.newSetFromMap(IdentityHashMap<T, Boolean>())
    private var generation = 0L
    val isEmpty: Boolean get() = active.isEmpty()

    fun add(service: T, stopping: Boolean) {
        active.add(service)
        ++generation
        if (stopping) stop(service)
    }

    fun remove(service: T) { active.remove(service) }

    suspend fun stopAndAwaitDestroyed(unbind: () -> Unit) {
        do {
            val observed = generation
            val services = active.toList()
            services.forEach(stop)
            unbind()
            services.forEach { awaitDestroyed(it) }
            // Drain already queued onCreate/onDestroy callbacks before accepting this snapshot.
            yield()
        } while (active.isNotEmpty() || generation != observed)
    }
}
