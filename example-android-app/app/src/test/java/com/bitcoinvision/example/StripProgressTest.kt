package com.bitcoinvision.example

import org.junit.Assert.*
import org.junit.Test
import uniffi.bitcoin_vision_mobile.StripProgressEvent
import uniffi.bitcoin_vision_mobile.StripProgressUpdate as Update
import uniffi.bitcoin_vision_mobile.StripWorkPhase as Phase

class StripProgressTest {
    @Test fun stages_and_geometry_replay_in_order_before_review() {
        val stream = StripProgressHandoff(7)
        var sequence = 0uL
        fun send(update: Update) = stream.onProgress(StripProgressEvent(++sequence, update))
        send(Update.Work(Phase.ADMITTING, 0u, null))
        send(Update.Photo(600u, 1200u))
        send(Update.Work(Phase.LOCATING, 0u, null))
        send(Update.Work(Phase.IDENTIFYING, 0u, 1u))
        send(Update.Region(0u, listOf(1.0, 2.0, 3.0, 2.0, 3.0, 4.0, 1.0, 4.0), false))
        send(Update.Work(Phase.IDENTIFYING, 1u, 1u))
        send(Update.Work(Phase.READING, 0u, 1u))
        send(Update.Region(0u, listOf(1.0, 2.0, 3.0, 2.0, 3.0, 4.0, 1.0, 4.0), true))
        send(Update.Work(Phase.READING, 1u, 1u))
        send(Update.Work(Phase.PACKING, 0u, 1u))
        send(Update.Work(Phase.PACKING, 1u, 1u))
        send(Update.Finished)
        stream.sealSuccess()
        var shown = stream.snapshot()!!
        assertEquals(0uL, shown.sequence)
        var clock = 0L
        while (!shown.finished) {
            stream.presented(shown.sequence, clock)
            clock += PROGRESS_STAGE_MS + 1
            shown = stream.nextFrame(clock)!!
        }
        assertEquals(sequence, shown.sequence)
        assertTrue(shown.regions[0u]!!.read)
        assertEquals(Phase.entries.toSet(), shown.stages)
        assertEquals(PhotoFrame(600, 1200), shown.frame)
        stream.presented(shown.sequence, clock)
        assertTrue(stream.playbackComplete(clock + PROGRESS_STAGE_MS + 1))
    }

    @Test fun truncated_stream_cannot_enter_review() {
        val stream = StripProgressHandoff(1)
        stream.onProgress(StripProgressEvent(1u, Update.Photo(50u, 50u)))
        stream.onProgress(StripProgressEvent(2u, Update.Finished))
        try { stream.sealSuccess(); fail("Incomplete stages accepted") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun malformed_geometry_is_rejected_before_it_can_be_drawn() {
        val stream = StripProgressHandoff(2)
        stream.onProgress(StripProgressEvent(1u, Update.Photo(50u, 50u)))
        try {
            stream.onProgress(StripProgressEvent(2u, Update.Region(0u, listOf(1.0, 2.0), false)))
            fail("Malformed region accepted")
        } catch (_: uniffi.bitcoin_vision_mobile.ProgressDeliveryException.Failed) { }
    }
}
