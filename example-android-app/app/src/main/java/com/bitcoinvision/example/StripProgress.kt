package com.bitcoinvision.example

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import uniffi.bitcoin_vision_mobile.ProgressDeliveryException
import uniffi.bitcoin_vision_mobile.StripProgressEvent
import uniffi.bitcoin_vision_mobile.StripProgressObserver
import uniffi.bitcoin_vision_mobile.StripProgressUpdate as Update
import uniffi.bitcoin_vision_mobile.StripWorkPhase as Phase

data class StripProgressRegion(val corners: List<Float>, val read: Boolean)

data class StripProgressState(
    val token: Int,
    val sequence: ULong = 0u,
    val phase: Phase = Phase.ADMITTING,
    val frame: PhotoFrame? = null,
    val regions: Map<UInt, StripProgressRegion> = emptyMap(),
    val completed: UInt = 0u,
    val total: UInt? = null,
    val stages: Set<Phase> = emptySet(),
    val finished: Boolean = false,
    val failed: Boolean = false,
) {
    val label: String get() = when (phase) {
        Phase.ADMITTING -> "Preparing photo"
        Phase.LOCATING -> "Finding strips"
        Phase.IDENTIFYING -> "Reading strip numbers"
        Phase.READING -> "Reading cells"
        Phase.PACKING -> "Preparing review"
    }

    fun reduce(event: StripProgressEvent): StripProgressState {
        require(!finished && !failed && event.sequence == sequence + 1uL) { "Strip progress is out of order" }
        val next = copy(sequence = event.sequence)
        return when (val update = event.update) {
            is Update.Photo -> {
                require(frame == null && update.width > 0u && update.height > 0u)
                next.copy(frame = PhotoFrame(update.width.toInt(), update.height.toInt()))
            }
            is Update.Work -> {
                require(update.phase.ordinal >= phase.ordinal &&
                    (update.total == null || update.completed <= update.total!!) &&
                    (update.phase != phase || (update.total == total && update.completed >= completed)))
                next.copy(phase = update.phase, completed = update.completed, total = update.total,
                    stages = stages + update.phase)
            }
            is Update.Region -> {
                require(frame != null && update.corners.size == 8 && update.corners.all(Double::isFinite) &&
                    (update.id in regions || regions.size < MAX_PROGRESS_REGIONS))
                next.copy(regions = regions + (update.id to StripProgressRegion(
                    update.corners.map(Double::toFloat), update.read)))
            }
            is Update.Replaced -> {
                require(frame != null && update.corners.size == 8 && update.corners.all(Double::isFinite) &&
                    update.parents.isNotEmpty() && update.parents.all { it in regions } &&
                    update.parents.toSet().size == update.parents.size && update.id !in regions)
                next.copy(regions = (regions - update.parents.toSet()) + (update.id to StripProgressRegion(
                    update.corners.map(Double::toFloat), update.read)))
            }
            is Update.Removed -> { require(update.id in regions); next.copy(regions = regions - update.id) }
            is Update.Finished -> next.copy(finished = true)
            is Update.Failed, is Update.Cancelled -> next.copy(failed = true)
        }
    }
}

/** Bounded, ordered playback. A frame is not retired until Compose drew it. */
internal class StripProgressHandoff(val token: Int) : StripProgressObserver {
    private var latest: StripProgressState? = StripProgressState(token)
    private var visible: StripProgressState? = latest
    private val pending = ArrayDeque<StripProgressEvent>()
    private var presentedAt: Long? = null
    private var dwellMs = PROGRESS_STAGE_MS
    private var sealed = false

    @Synchronized fun detach() { latest = null; visible = null; pending.clear() }
    @Synchronized fun snapshot(): StripProgressState? = visible
    @Synchronized fun hasEvents(): Boolean = latest?.sequence != 0uL
    @Synchronized fun presented(sequence: ULong, nowMs: Long = progressClockMs()) {
        if (visible?.sequence == sequence && presentedAt == null) presentedAt = nowMs
    }
    @Synchronized fun nextFrame(nowMs: Long = progressClockMs()): StripProgressState? {
        val current = visible ?: return null
        val shown = presentedAt ?: return current
        if (nowMs - shown < dwellMs || pending.isEmpty()) return current
        val next = current.reduce(pending.removeFirst())
        visible = next
        presentedAt = null
        dwellMs = if (next.phase != current.phase || next.finished) PROGRESS_STAGE_MS else PROGRESS_FRAME_MS
        return next
    }
    @Synchronized fun sealSuccess() {
        val end = latest ?: throw CancellationException("Strip progress detached")
        require(end.finished && !end.failed && end.frame != null && end.stages == Phase.entries.toSet()) {
            "The strip scanner did not complete its stages"
        }
        sealed = true
    }
    @Synchronized fun playbackComplete(nowMs: Long = progressClockMs()): Boolean =
        sealed && pending.isEmpty() && visible?.finished == true &&
            presentedAt?.let { nowMs - it >= dwellMs } == true

    suspend fun awaitPlayback() {
        sealSuccess()
        while (!playbackComplete()) {
            if (snapshot() == null) throw CancellationException("Strip progress detached")
            delay(PROGRESS_FRAME_MS)
        }
    }

    @Synchronized override fun onProgress(event: StripProgressEvent) {
        val old = latest ?: throw ProgressDeliveryException.Detached()
        if (pending.size >= MAX_PROGRESS_EVENTS) throw ProgressDeliveryException.Failed()
        val frozen = when (val u = event.update) {
            is Update.Region -> Update.Region(u.id, u.corners.toList(), u.read)
            is Update.Replaced -> Update.Replaced(u.id, u.corners.toList(), u.read, u.parents.toList())
            else -> u
        }
        val copy = StripProgressEvent(event.sequence, frozen)
        try { latest = old.reduce(copy) } catch (_: IllegalArgumentException) {
            throw ProgressDeliveryException.Failed()
        }
        pending.addLast(copy)
    }
}
